#include "redirect_url.h"

#include <algorithm>
#include <cctype>
#include <optional>
#include <stdexcept>
#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

struct URLReference {
  std::optional<std::string> scheme;
  bool has_authority = false;
  std::string authority;
  std::string path;
  std::optional<std::string> query;
  std::optional<std::string> fragment;
};

struct HTTPURL {
  std::string scheme;
  std::string host;
  std::optional<unsigned int> port;
  std::string path;
  std::optional<std::string> query;
  std::optional<std::string> fragment;
};

std::string LowerASCII(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char byte) {
                   return static_cast<char>(std::tolower(byte));
                 });
  return value;
}

void ValidateURLCharacters(const std::string& value) {
  for (const unsigned char byte : value) {
    if (byte <= 0x20 || byte == 0x7f || byte == '\\') {
      throw std::runtime_error("Update URL contains invalid characters.");
    }
  }
}

bool ValidScheme(const std::string& value) {
  if (value.empty() ||
      !std::isalpha(static_cast<unsigned char>(value.front()))) {
    return false;
  }
  return std::all_of(value.begin() + 1, value.end(), [](unsigned char byte) {
    return std::isalnum(byte) || byte == '+' || byte == '-' || byte == '.';
  });
}

URLReference ParseReference(const std::string& input) {
  ValidateURLCharacters(input);
  URLReference result;
  std::string remainder = input;
  const std::size_t fragment = remainder.find('#');
  if (fragment != std::string::npos) {
    result.fragment = remainder.substr(fragment + 1);
    remainder.erase(fragment);
  }
  const std::size_t query = remainder.find('?');
  if (query != std::string::npos) {
    result.query = remainder.substr(query + 1);
    remainder.erase(query);
  }

  const std::size_t colon = remainder.find(':');
  const std::size_t slash = remainder.find('/');
  if (colon != std::string::npos &&
      (slash == std::string::npos || colon < slash)) {
    const std::string scheme = remainder.substr(0, colon);
    if (!ValidScheme(scheme)) {
      throw std::runtime_error("Redirect URL scheme is invalid.");
    }
    result.scheme = LowerASCII(scheme);
    remainder.erase(0, colon + 1);
  }

  if (remainder.rfind("//", 0) == 0) {
    result.has_authority = true;
    remainder.erase(0, 2);
    const std::size_t path = remainder.find('/');
    result.authority = remainder.substr(0, path);
    remainder = path == std::string::npos ? std::string()
                                          : remainder.substr(path);
  }
  result.path = remainder;
  return result;
}

unsigned int ParsePort(const std::string& value) {
  if (value.empty() ||
      !std::all_of(value.begin(), value.end(), [](unsigned char byte) {
        return std::isdigit(byte);
      })) {
    throw std::runtime_error("HTTP update URL port is invalid.");
  }
  unsigned long parsed = 0;
  try {
    parsed = std::stoul(value);
  } catch (const std::exception&) {
    throw std::runtime_error("HTTP update URL port is invalid.");
  }
  if (parsed == 0 || parsed > 65535) {
    throw std::runtime_error("HTTP update URL port is invalid.");
  }
  return static_cast<unsigned int>(parsed);
}

void ParseAuthority(const std::string& authority, HTTPURL* result) {
  if (authority.empty() || authority.find('@') != std::string::npos) {
    throw std::runtime_error("HTTP update URL credentials are forbidden.");
  }
  std::string port;
  if (authority.front() == '[') {
    const std::size_t close = authority.find(']');
    if (close == std::string::npos || close == 1) {
      throw std::runtime_error("HTTP update URL IPv6 host is invalid.");
    }
    result->host = "[" + LowerASCII(authority.substr(1, close - 1)) + "]";
    const std::string suffix = authority.substr(close + 1);
    if (!suffix.empty()) {
      if (suffix.front() != ':' || suffix.size() == 1) {
        throw std::runtime_error("HTTP update URL authority is invalid.");
      }
      port = suffix.substr(1);
    }
  } else {
    const std::size_t colon = authority.rfind(':');
    if (colon != std::string::npos) {
      if (authority.find(':') != colon) {
        throw std::runtime_error(
            "IPv6 update URL hosts must use brackets.");
      }
      if (colon + 1 == authority.size()) {
        throw std::runtime_error("HTTP update URL port is invalid.");
      }
      result->host = LowerASCII(authority.substr(0, colon));
      port = authority.substr(colon + 1);
    } else {
      result->host = LowerASCII(authority);
    }
  }
  if (result->host.empty()) {
    throw std::runtime_error("HTTP update URL must include a host.");
  }
  if (!port.empty()) result->port = ParsePort(port);
  if (result->port.has_value() &&
      ((result->scheme == "http" && *result->port == 80) ||
       (result->scheme == "https" && *result->port == 443))) {
    result->port.reset();
  }
}

HTTPURL ParseAbsoluteHTTPURL(const std::string& value) {
  const URLReference reference = ParseReference(value);
  if (!reference.scheme.has_value() || !reference.has_authority ||
      (*reference.scheme != "http" && *reference.scheme != "https")) {
    throw std::runtime_error("HTTP update URL must be absolute.");
  }
  HTTPURL result;
  result.scheme = *reference.scheme;
  ParseAuthority(reference.authority, &result);
  result.path = reference.path.empty() ? "/" : reference.path;
  if (result.path.front() != '/') {
    throw std::runtime_error("HTTP update URL path is invalid.");
  }
  result.query = reference.query;
  result.fragment = reference.fragment;
  return result;
}

void RemoveLastSegment(std::string* output) {
  const std::size_t slash = output->find_last_of('/');
  if (slash == std::string::npos) {
    output->clear();
  } else {
    output->erase(slash);
  }
}

std::string RemoveDotSegments(std::string input) {
  std::string output;
  while (!input.empty()) {
    if (input.rfind("../", 0) == 0) {
      input.erase(0, 3);
    } else if (input.rfind("./", 0) == 0) {
      input.erase(0, 2);
    } else if (input.rfind("/./", 0) == 0) {
      input.replace(0, 3, "/");
    } else if (input == "/.") {
      input = "/";
    } else if (input.rfind("/../", 0) == 0) {
      input.replace(0, 4, "/");
      RemoveLastSegment(&output);
    } else if (input == "/..") {
      input = "/";
      RemoveLastSegment(&output);
    } else if (input == "." || input == "..") {
      input.clear();
    } else {
      const std::size_t next =
          input.front() == '/' ? input.find('/', 1) : input.find('/');
      if (next == std::string::npos) {
        output += input;
        input.clear();
      } else {
        output += input.substr(0, next);
        input.erase(0, next);
      }
    }
  }
  return output;
}

std::string MergePaths(const std::string& base, const std::string& relative) {
  const std::size_t slash = base.find_last_of('/');
  return (slash == std::string::npos ? std::string("/")
                                     : base.substr(0, slash + 1)) +
         relative;
}

std::string Serialize(const HTTPURL& value, bool include_fragment) {
  std::string result = value.scheme + "://" + value.host;
  if (value.port.has_value()) result += ":" + std::to_string(*value.port);
  result += value.path.empty() ? "/" : value.path;
  if (value.query.has_value()) result += "?" + *value.query;
  if (include_fragment && value.fragment.has_value()) {
    result += "#" + *value.fragment;
  }
  return result;
}

}  // namespace

std::string ResolveRedirectURL(const std::string& source,
                               const std::string& location) {
  const HTTPURL base = ParseAbsoluteHTTPURL(source);
  const URLReference reference = ParseReference(location);
  HTTPURL target;
  if (reference.scheme.has_value()) {
    target = ParseAbsoluteHTTPURL(location);
    target.path = RemoveDotSegments(target.path);
  } else if (reference.has_authority) {
    target = ParseAbsoluteHTTPURL(base.scheme + ":" + location);
    target.path = RemoveDotSegments(target.path);
  } else {
    target = base;
    if (reference.path.empty()) {
      if (reference.query.has_value()) target.query = reference.query;
    } else {
      target.path = RemoveDotSegments(
          reference.path.front() == '/'
              ? reference.path
              : MergePaths(base.path, reference.path));
      target.query = reference.query;
    }
    target.fragment = reference.fragment;
  }
  if (base.scheme == "https" && target.scheme != "https") {
    throw std::runtime_error("HTTPS redirect downgrade is forbidden.");
  }
  return Serialize(target, true);
}

std::string HTTPRequestTarget(const std::string& url) {
  const HTTPURL parsed = ParseAbsoluteHTTPURL(url);
  std::string result = parsed.path.empty() ? "/" : parsed.path;
  if (parsed.query.has_value()) result += "?" + *parsed.query;
  return result;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
