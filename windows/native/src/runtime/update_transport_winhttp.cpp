#include "update_transport_winhttp.h"

#include <windows.h>

#include <bcrypt.h>
#include <winhttp.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
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

struct InternetCloser {
  void operator()(void* handle) const {
    if (handle != nullptr) WinHttpCloseHandle(handle);
  }
};
using InternetHandle = std::unique_ptr<void, InternetCloser>;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) throw std::runtime_error("Invalid UTF-8 transport value.");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw std::runtime_error("UTF-8 conversion failed.");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) throw std::runtime_error("Invalid UTF-16 transport value.");
  std::string result(static_cast<std::size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length,
                      nullptr, nullptr);
  return result;
}

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
  return scheme;
}

std::string FilePathFromURL(const std::string& url) {
  const std::string prefix = "file:///";
  if (url.rfind(prefix, 0) != 0) {
    throw std::runtime_error("file URL must be absolute.");
  }
  return url.substr(prefix.size());
}

std::int64_t FileSize(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  return input ? static_cast<std::int64_t>(input.tellg()) : 0;
}

std::string HashFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Downloaded artifact is missing.");
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(
          &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0 ||
      BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
    throw std::runtime_error("BCrypt artifact hash initialization failed.");
  }
  std::vector<char> buffer(64 * 1024);
  NTSTATUS status = 0;
  while (input && status >= 0) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize length = input.gcount();
    if (length > 0) {
      status = BCryptHashData(
          hash, reinterpret_cast<PUCHAR>(buffer.data()),
          static_cast<ULONG>(length), 0);
    }
  }
  std::vector<unsigned char> digest(32);
  if (status >= 0) {
    status = BCryptFinishHash(
        hash, digest.data(), static_cast<ULONG>(digest.size()), 0);
  }
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (status < 0) throw std::runtime_error("BCrypt artifact hash failed.");
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned char byte : digest) {
    output << std::setw(2) << static_cast<int>(byte);
  }
  return output.str();
}

std::wstring QueryHeader(HINTERNET request, DWORD query) {
  DWORD bytes = 0;
  WinHttpQueryHeaders(request, query, WINHTTP_HEADER_NAME_BY_INDEX, nullptr,
                      &bytes, WINHTTP_NO_HEADER_INDEX);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes == 0) return {};
  std::wstring value(bytes / sizeof(wchar_t), L'\0');
  if (!WinHttpQueryHeaders(request, query, WINHTTP_HEADER_NAME_BY_INDEX,
                           value.data(), &bytes, WINHTTP_NO_HEADER_INDEX)) {
    return {};
  }
  while (!value.empty() && value.back() == L'\0') value.pop_back();
  return value;
}

struct ParsedURL {
  std::wstring host;
  INTERNET_PORT port = 0;
  bool secure = false;
};

ParsedURL ParseHTTPURL(const std::string& url) {
  const std::wstring wide = Utf8ToWide(url);
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  components.dwHostNameLength = static_cast<DWORD>(-1);
  components.dwUserNameLength = static_cast<DWORD>(-1);
  components.dwPasswordLength = static_cast<DWORD>(-1);
  components.dwUrlPathLength = static_cast<DWORD>(-1);
  components.dwExtraInfoLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &components) ||
      components.dwHostNameLength == 0 ||
      (components.nScheme != INTERNET_SCHEME_HTTP &&
       components.nScheme != INTERNET_SCHEME_HTTPS) ||
      components.dwUserNameLength != 0 ||
      components.dwPasswordLength != 0) {
    throw std::runtime_error("HTTP update URL must include a host.");
  }
  ParsedURL result;
  result.host.assign(components.lpszHostName, components.dwHostNameLength);
  result.port = components.nPort;
  result.secure = components.nScheme == INTERNET_SCHEME_HTTPS;
  return result;
}

struct Response {
  DWORD status = 0;
  std::string location;
  std::string content_range;
  std::vector<std::uint8_t> body;
};

Response Perform(const std::string& url,
                 const TransportOptions& options,
                 std::int64_t resume,
                 std::ofstream* artifact,
                 std::int64_t maximum_bytes,
                 const DownloadProgress& progress) {
  const ParsedURL parsed = ParseHTTPURL(url);
  const std::wstring request_target = Utf8ToWide(HTTPRequestTarget(url));
  InternetHandle session(WinHttpOpen(
      L"desktop_updater/2.7", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
  if (!session) throw std::runtime_error("WinHttpOpen failed.");
  WinHttpSetTimeouts(session.get(), static_cast<int>(options.timeout_milliseconds),
                     static_cast<int>(options.timeout_milliseconds),
                     static_cast<int>(options.timeout_milliseconds),
                     static_cast<int>(options.timeout_milliseconds));
  InternetHandle connection(
      WinHttpConnect(session.get(), parsed.host.c_str(), parsed.port, 0));
  if (!connection) throw std::runtime_error("WinHTTP connection failed.");
  InternetHandle request(WinHttpOpenRequest(
      connection.get(), L"GET", request_target.c_str(), nullptr,
      WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
      parsed.secure ? WINHTTP_FLAG_SECURE : 0));
  if (!request) throw std::runtime_error("WinHTTP request creation failed.");
  DWORD disabled = WINHTTP_DISABLE_REDIRECTS;
  if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE,
                        &disabled, sizeof(disabled))) {
    throw std::runtime_error("WinHTTP redirect policy failed.");
  }
  const auto headers = options.request_headers_provider
                           ? options.request_headers_provider(url)
                           : std::map<std::string, std::string>();
  for (const auto& entry : headers) {
    const std::wstring header = Utf8ToWide(entry.first + ": " + entry.second);
    if (!WinHttpAddRequestHeaders(request.get(), header.c_str(),
                                  static_cast<DWORD>(header.size()),
                                  WINHTTP_ADDREQ_FLAG_ADD |
                                      WINHTTP_ADDREQ_FLAG_REPLACE)) {
      throw std::runtime_error("WinHTTP request header failed.");
    }
  }
  if (resume > 0) {
    const std::wstring range =
        L"Range: bytes=" + std::to_wstring(resume) + L"-";
    WinHttpAddRequestHeaders(request.get(), range.c_str(),
                             static_cast<DWORD>(range.size()),
                             WINHTTP_ADDREQ_FLAG_ADD |
                                 WINHTTP_ADDREQ_FLAG_REPLACE);
  }
  if (!WinHttpSendRequest(request.get(), WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                          WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
      !WinHttpReceiveResponse(request.get(), nullptr)) {
    throw std::runtime_error("WinHTTP request failed.");
  }
  Response response;
  DWORD status_bytes = sizeof(response.status);
  WinHttpQueryHeaders(request.get(),
                      WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                      WINHTTP_HEADER_NAME_BY_INDEX, &response.status,
                      &status_bytes, WINHTTP_NO_HEADER_INDEX);
  response.location = WideToUtf8(QueryHeader(request.get(), WINHTTP_QUERY_LOCATION));
  response.content_range =
      WideToUtf8(QueryHeader(request.get(), WINHTTP_QUERY_CONTENT_RANGE));
  if (response.status >= 300 && response.status < 400) return response;

  std::int64_t received = 0;
  while (true) {
    DWORD available = 0;
    if (!WinHttpQueryDataAvailable(request.get(), &available)) {
      throw std::runtime_error("WinHTTP read failed.");
    }
    if (available == 0) break;
    std::vector<std::uint8_t> buffer(available);
    DWORD read = 0;
    if (!WinHttpReadData(request.get(), buffer.data(), available, &read)) {
      throw std::runtime_error("WinHTTP read failed.");
    }
    if (received > maximum_bytes - static_cast<std::int64_t>(read)) {
      throw std::runtime_error("Download exceeded its byte limit.");
    }
    if (artifact != nullptr) {
      artifact->write(reinterpret_cast<const char*>(buffer.data()), read);
      if (!*artifact) throw std::runtime_error("Unable to write .part file.");
    } else {
      response.body.insert(response.body.end(), buffer.begin(),
                           buffer.begin() + read);
    }
    received += read;
    if (progress) progress(resume + received, -1);
  }
  return response;
}

bool RedirectStatus(DWORD status) {
  return status == 301 || status == 302 || status == 303 || status == 307 ||
         status == 308;
}

bool RetryableStatus(DWORD status) {
  return status == 408 || status == 429 || status >= 500;
}

std::vector<std::uint8_t> ReadBoundedFile(const std::filesystem::path& path,
                                          std::int64_t maximum) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("file URL could not be opened.");
  std::vector<std::uint8_t> result;
  std::vector<char> buffer(64 * 1024);
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize read = input.gcount();
    if (static_cast<std::int64_t>(result.size()) > maximum - read) {
      throw std::runtime_error("file URL exceeded its byte limit.");
    }
    result.insert(result.end(), buffer.begin(), buffer.begin() + read);
  }
  return result;
}

}  // namespace

WinHttpUpdateTransport::WinHttpUpdateTransport(TransportOptions options)
    : options_(std::move(options)) {
  if (options_.maximum_redirects < 0 ||
      options_.maximum_redirects > maximumRedirects ||
      options_.maximum_retries <= 0) {
    throw std::invalid_argument("Invalid WinHTTP transport limits.");
  }
}

std::vector<std::uint8_t> WinHttpUpdateTransport::DownloadMetadata(
    const std::string& initial_url) {
  if (Scheme(initial_url) == "file") {
    return ReadBoundedFile(std::filesystem::u8path(FilePathFromURL(initial_url)),
                           options_.maximum_metadata_bytes);
  }
  std::string url = initial_url;
  for (int redirects = 0; redirects <= options_.maximum_redirects; ++redirects) {
    for (int attempt = 0; attempt < options_.maximum_retries; ++attempt) {
      try {
        Response response = Perform(
            url, options_, 0, nullptr, options_.maximum_metadata_bytes, {});
        if (RedirectStatus(response.status)) {
          url = ResolveRedirectURL(url, response.location);
          break;
        }
        if (response.status >= 200 && response.status < 300) return response.body;
        if (!RetryableStatus(response.status)) {
          throw std::runtime_error("Metadata HTTP status failed.");
        }
      } catch (...) {
        if (attempt + 1 == options_.maximum_retries) throw;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }
  throw std::runtime_error("Update redirect limit exceeded.");
}

void WinHttpUpdateTransport::DownloadArtifact(
    const ArtifactDownloadRequest& download) {
  const std::filesystem::path destination =
      std::filesystem::u8path(download.destination_path);
  std::filesystem::path partial = destination;
  partial += L".part";
  try {
    if (Scheme(download.url) == "file") {
      const std::vector<std::uint8_t> bytes = ReadBoundedFile(
          std::filesystem::u8path(FilePathFromURL(download.url)),
          download.expected_length);
      std::ofstream output(partial, std::ios::binary | std::ios::trunc);
      output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    } else {
      std::string url = download.url;
      bool completed = false;
      for (int redirects = 0; redirects <= options_.maximum_redirects;
           ++redirects) {
        bool redirected = false;
        for (int attempt = 0; attempt < options_.maximum_retries; ++attempt) {
          try {
            const std::int64_t resume = FileSize(partial);
            if (resume > download.expected_length) {
              std::filesystem::remove(partial);
              continue;
            }
            std::ofstream output(
                partial,
                std::ios::binary |
                    (resume > 0 ? std::ios::app : std::ios::trunc));
            Response response = Perform(
                url, options_, resume, &output,
                download.expected_length - resume, download.progress);
            output.close();
            if (RedirectStatus(response.status)) {
              url = ResolveRedirectURL(url, response.location);
              redirected = true;
              break;
            }
            if (resume > 0 && response.status == 200) {
              std::filesystem::remove(partial);
              --attempt;
              continue;
            }
            if (resume > 0 && response.status == 206) {
              const std::string expected =
                  "bytes " + std::to_string(resume) + "-";
              if (response.content_range.rfind(expected, 0) != 0) {
                throw std::runtime_error(
                    "Content-Range does not match .part file.");
              }
            }
            if (response.status >= 200 && response.status < 300) {
              redirected = false;
              completed = true;
              break;
            }
            if (!RetryableStatus(response.status)) {
              throw std::runtime_error("Artifact HTTP status failed.");
            }
          } catch (...) {
            if (attempt + 1 == options_.maximum_retries) throw;
          }
          std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!redirected) break;
      }
      if (!completed) {
        throw std::runtime_error("Update redirect limit exceeded.");
      }
    }
    if (FileSize(partial) != download.expected_length) {
      throw std::runtime_error("Artifact length verification failed.");
    }
    if (HashFile(partial) != Lower(download.expected_sha256)) {
      throw std::runtime_error("Artifact SHA-256 verification failed.");
    }
    std::error_code error;
    std::filesystem::remove(destination, error);
    error.clear();
    std::filesystem::rename(partial, destination, error);
    if (error) {
      throw std::runtime_error("Unable to finalize artifact download.");
    }
  } catch (...) {
    std::error_code ignored;
    std::filesystem::remove(partial, ignored);
    throw;
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
