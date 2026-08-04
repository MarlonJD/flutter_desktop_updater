#include "update_transport_curl.h"

#include <curl/curl.h>
#include <openssl/evp.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

constexpr int maximumRedirects = 5;

struct ResponseContext {
  std::vector<std::uint8_t>* metadata = nullptr;
  std::ofstream* artifact = nullptr;
  std::int64_t maximum_bytes = 0;
  std::int64_t received = 0;
  std::int64_t resume_offset = 0;
  long status = 0;
  std::string content_range;
  DownloadProgress progress;
};

struct CurlHandleDeleter {
  void operator()(CURL* handle) const {
    if (handle != nullptr) curl_easy_cleanup(handle);
  }
};

struct CurlHeadersDeleter {
  void operator()(curl_slist* headers) const {
    if (headers != nullptr) curl_slist_free_all(headers);
  }
};

using CurlHandle = std::unique_ptr<CURL, CurlHandleDeleter>;
using CurlHeaders = std::unique_ptr<curl_slist, CurlHeadersDeleter>;

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](char byte) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(byte)));
  });
  return value;
}

std::string Scheme(const std::string& url) {
  const std::size_t separator = url.find(':');
  if (separator == std::string::npos || separator == 0) {
    throw std::runtime_error("Update URL must be absolute.");
  }
  const std::string scheme = Lower(url.substr(0, separator));
  if (scheme != "https" && scheme != "http" && scheme != "file") {
    throw std::runtime_error("Unsupported update URL scheme.");
  }
  if ((scheme == "https" || scheme == "http") &&
      url.find("//", separator + 1) != separator + 1) {
    throw std::runtime_error("HTTP update URL must include a host.");
  }
  return scheme;
}

std::int64_t FileSize(const std::string& path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  return file ? static_cast<std::int64_t>(file.tellg()) : 0;
}

std::size_t WriteCallback(char* bytes,
                          std::size_t size,
                          std::size_t count,
                          void* context_pointer) {
  ResponseContext& context = *static_cast<ResponseContext*>(context_pointer);
  const std::size_t length = size * count;
  if (context.status >= 300 && context.status < 400) return length;
  if (context.received > context.maximum_bytes -
                             static_cast<std::int64_t>(length)) {
    return 0;
  }
  if (context.metadata != nullptr) {
    context.metadata->insert(context.metadata->end(), bytes, bytes + length);
  } else if (context.artifact != nullptr) {
    context.artifact->write(bytes, static_cast<std::streamsize>(length));
    if (!*context.artifact) return 0;
  }
  context.received += static_cast<std::int64_t>(length);
  if (context.progress) {
    context.progress(context.resume_offset + context.received, -1);
  }
  return length;
}

std::size_t HeaderCallback(char* bytes,
                           std::size_t size,
                           std::size_t count,
                           void* context_pointer) {
  ResponseContext& context = *static_cast<ResponseContext*>(context_pointer);
  const std::size_t length = size * count;
  const std::string line(bytes, length);
  if (line.rfind("HTTP/", 0) == 0) {
    std::istringstream input(line);
    std::string protocol;
    input >> protocol >> context.status;
  } else {
    const std::string lower = Lower(line);
    if (lower.rfind("content-range:", 0) == 0) {
      context.content_range = line.substr(std::string("Content-Range:").size());
      while (!context.content_range.empty() &&
             std::isspace(static_cast<unsigned char>(
                 context.content_range.front()))) {
        context.content_range.erase(context.content_range.begin());
      }
    }
  }
  return length;
}

CurlHeaders MakeHeaders(const std::map<std::string, std::string>& values) {
  curl_slist* headers = nullptr;
  for (const auto& entry : values) {
    headers = curl_slist_append(
        headers, (entry.first + ": " + entry.second).c_str());
    if (headers == nullptr) throw std::bad_alloc();
  }
  return CurlHeaders(headers);
}

bool RetryableStatus(long status) {
  return status == 408 || status == 429 || status >= 500;
}

bool RedirectStatus(long status) {
  return status == 301 || status == 302 || status == 303 || status == 307 ||
         status == 308;
}

std::string HexDigest(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Downloaded artifact is missing.");
  std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(
      EVP_MD_CTX_new(), EVP_MD_CTX_free);
  if (!context || EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1) {
    throw std::runtime_error("Artifact SHA-256 initialization failed.");
  }
  std::vector<char> buffer(64 * 1024);
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize length = input.gcount();
    if (length > 0 &&
        EVP_DigestUpdate(context.get(), buffer.data(),
                         static_cast<std::size_t>(length)) != 1) {
      throw std::runtime_error("Artifact SHA-256 update failed.");
    }
  }
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int length = 0;
  if (EVP_DigestFinal_ex(context.get(), digest, &length) != 1 || length != 32) {
    throw std::runtime_error("Artifact SHA-256 finalization failed.");
  }
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned int index = 0; index < length; ++index) {
    output << std::setw(2) << static_cast<int>(digest[index]);
  }
  return output.str();
}

struct PerformResult {
  CURLcode code = CURLE_OK;
  long status = 0;
  std::string redirect_url;
  std::string content_range;
};

PerformResult Perform(const std::string& url,
                      const TransportOptions& options,
                      std::int64_t resume_offset,
                      ResponseContext* context) {
  CurlHandle handle(curl_easy_init());
  if (!handle) throw std::runtime_error("curl_easy_init failed.");
  const auto provided = options.request_headers_provider
                            ? options.request_headers_provider(url)
                            : std::map<std::string, std::string>();
  CurlHeaders headers = MakeHeaders(provided);
  curl_easy_setopt(handle.get(), CURLOPT_URL, url.c_str());
  curl_easy_setopt(handle.get(), CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(handle.get(), CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(handle.get(), CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(handle.get(), CURLOPT_CONNECTTIMEOUT_MS,
                   options.timeout_milliseconds);
  curl_easy_setopt(handle.get(), CURLOPT_TIMEOUT_MS, options.timeout_milliseconds);
  curl_easy_setopt(handle.get(), CURLOPT_HTTPHEADER, headers.get());
  curl_easy_setopt(handle.get(), CURLOPT_WRITEFUNCTION, WriteCallback);
  curl_easy_setopt(handle.get(), CURLOPT_WRITEDATA, context);
  curl_easy_setopt(handle.get(), CURLOPT_HEADERFUNCTION, HeaderCallback);
  curl_easy_setopt(handle.get(), CURLOPT_HEADERDATA, context);
  if (resume_offset > 0) {
    curl_easy_setopt(handle.get(), CURLOPT_RESUME_FROM_LARGE,
                     static_cast<curl_off_t>(resume_offset));
  }
  PerformResult result;
  result.code = curl_easy_perform(handle.get());
  curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &result.status);
  char* redirect = nullptr;
  curl_easy_getinfo(handle.get(), CURLINFO_REDIRECT_URL, &redirect);
  if (redirect != nullptr) result.redirect_url = redirect;
  result.content_range = context->content_range;
  return result;
}

void ValidateRedirect(const std::string& source, const std::string& target) {
  if (target.empty()) throw std::runtime_error("Redirect is missing Location.");
  if (Scheme(source) == "https" && Scheme(target) != "https") {
    throw std::runtime_error("HTTPS redirect downgrade is forbidden.");
  }
}

}  // namespace

CurlUpdateTransport::CurlUpdateTransport(TransportOptions options)
    : options_(std::move(options)) {
  static const CURLcode initialized = curl_global_init(CURL_GLOBAL_DEFAULT);
  if (initialized != CURLE_OK) {
    throw std::runtime_error("libcurl global initialization failed.");
  }
  if (options_.maximum_redirects < 0 ||
      options_.maximum_redirects > maximumRedirects ||
      options_.maximum_retries <= 0 || options_.timeout_milliseconds <= 0 ||
      options_.maximum_metadata_bytes <= 0) {
    throw std::invalid_argument("Invalid libcurl transport limits.");
  }
}

std::vector<std::uint8_t> CurlUpdateTransport::DownloadMetadata(
    const std::string& initial_url) {
  std::string url = initial_url;
  Scheme(url);
  for (int redirect_count = 0; redirect_count <= options_.maximum_redirects;
       ++redirect_count) {
    for (int attempt = 0; attempt < options_.maximum_retries; ++attempt) {
      std::vector<std::uint8_t> bytes;
      ResponseContext context;
      context.metadata = &bytes;
      context.maximum_bytes = options_.maximum_metadata_bytes;
      const PerformResult result = Perform(url, options_, 0, &context);
      if (RedirectStatus(result.status)) {
        ValidateRedirect(url, result.redirect_url);
        url = result.redirect_url;
        break;
      }
      if (result.code == CURLE_OK &&
          (result.status == 0 || (result.status >= 200 && result.status < 300))) {
        return bytes;
      }
      if (attempt + 1 == options_.maximum_retries ||
          (result.code == CURLE_OK && !RetryableStatus(result.status))) {
        throw std::runtime_error("Metadata download failed.");
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }
  throw std::runtime_error("Update redirect limit exceeded.");
}

void CurlUpdateTransport::DownloadArtifact(
    const ArtifactDownloadRequest& request) {
  Scheme(request.url);
  if (request.expected_length < 0 || request.expected_sha256.size() != 64) {
    throw std::invalid_argument("Artifact integrity expectations are invalid.");
  }
  const std::string partial_path = request.destination_path + ".part";
  std::string url = request.url;
  try {
    for (int redirect_count = 0; redirect_count <= options_.maximum_redirects;
         ++redirect_count) {
      bool redirected = false;
      for (int attempt = 0; attempt < options_.maximum_retries; ++attempt) {
        std::int64_t resume = FileSize(partial_path);
        if (resume > request.expected_length) {
          std::remove(partial_path.c_str());
          resume = 0;
        }
        std::ofstream output(
            partial_path,
            std::ios::binary | (resume > 0 ? std::ios::app : std::ios::trunc));
        if (!output) throw std::runtime_error("Unable to open .part file.");
        ResponseContext context;
        context.artifact = &output;
        context.maximum_bytes = request.expected_length - resume;
        context.resume_offset = resume;
        context.progress = request.progress;
        const PerformResult result = Perform(url, options_, resume, &context);
        output.close();
        if (RedirectStatus(result.status)) {
          ValidateRedirect(url, result.redirect_url);
          url = result.redirect_url;
          redirected = true;
          break;
        }
        if (resume > 0 && result.status == 200) {
          std::remove(partial_path.c_str());
          --attempt;
          continue;
        }
        if (resume > 0 && result.status == 206) {
          const std::string expected = "bytes " + std::to_string(resume) + "-";
          if (result.content_range.rfind(expected, 0) != 0) {
            throw std::runtime_error("Content-Range does not match .part file.");
          }
        }
        if (result.code == CURLE_OK &&
            (result.status == 0 || (result.status >= 200 && result.status < 300))) {
          if (FileSize(partial_path) != request.expected_length) {
            throw std::runtime_error("Artifact length verification failed.");
          }
          if (HexDigest(partial_path) != Lower(request.expected_sha256)) {
            throw std::runtime_error("Artifact SHA-256 verification failed.");
          }
          std::remove(request.destination_path.c_str());
          if (std::rename(partial_path.c_str(), request.destination_path.c_str()) !=
              0) {
            throw std::runtime_error("Unable to finalize artifact download.");
          }
          return;
        }
        if (attempt + 1 == options_.maximum_retries ||
            (result.code == CURLE_OK && !RetryableStatus(result.status))) {
          throw std::runtime_error("Artifact download failed.");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
      if (!redirected) break;
    }
    throw std::runtime_error("Update redirect limit exceeded.");
  } catch (...) {
    std::remove(partial_path.c_str());
    throw;
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
