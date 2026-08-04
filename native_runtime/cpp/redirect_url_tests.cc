#include "redirect_url.h"

#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void ExpectEqual(const std::string& actual,
                 const std::string& expected,
                 const char* message) {
  if (actual != expected) {
    throw std::runtime_error(std::string(message) + ": expected " + expected +
                             ", got " + actual);
  }
}

template <typename Function>
void ExpectRejected(Function function, const char* message) {
  try {
    function();
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error(message);
}

}  // namespace

int main() {
  using desktop_updater::runtime::internal::HTTPRequestTarget;
  using desktop_updater::runtime::internal::ResolveRedirectURL;
  try {
    const std::string base =
        "http://Example.COM:80/a//b/c?old=1#base-fragment";
    ExpectEqual(ResolveRedirectURL(base, ""),
                "http://example.com/a//b/c?old=1",
                "Empty redirect reference differs");
    ExpectEqual(ResolveRedirectURL(base, "?new=2"),
                "http://example.com/a//b/c?new=2",
                "Query-only redirect differs");
    ExpectEqual(ResolveRedirectURL(base, "#next"),
                "http://example.com/a//b/c?old=1#next",
                "Fragment-only redirect did not inherit the base query");
    ExpectEqual(ResolveRedirectURL(base, "?new=2#next"),
                "http://example.com/a//b/c?new=2#next",
                "Query-fragment redirect differs");
    ExpectEqual(ResolveRedirectURL(base, "/root/./x/../metadata"),
                "http://example.com/root/metadata",
                "Root-relative redirect differs");
    ExpectEqual(ResolveRedirectURL(base, "../metadata"),
                "http://example.com/a//metadata",
                "Parent-relative redirect collapsed non-dot slashes");
    ExpectEqual(
        ResolveRedirectURL("https://example.com/source",
                           "//Other.EXAMPLE:443/a//b"),
        "https://other.example/a//b",
        "Scheme-relative default-port redirect differs");
    ExpectEqual(ResolveRedirectURL("http://example.com:8080/a/b", "../c"),
                "http://example.com:8080/c",
                "Explicit non-default port was not preserved");
    ExpectEqual(
        ResolveRedirectURL("https://[2001:DB8::1]:443/a/b?x=1", "#v6"),
        "https://[2001:db8::1]/a/b?x=1#v6",
        "IPv6 redirect normalization differs");
    ExpectEqual(HTTPRequestTarget(
                    "https://[2001:db8::1]/a//b?x=1#never-send"),
                "/a//b?x=1",
                "HTTP request target included a fragment");
    ExpectEqual(HTTPRequestTarget("http://example.com#fragment"), "/",
                "Empty HTTP path target differs");

    ExpectRejected(
        [] { ResolveRedirectURL("http://user@example.com/a", "/b"); },
        "Credentialed source URL was accepted");
    ExpectRejected(
        [] {
          ResolveRedirectURL("http://example.com/a",
                             "http://user@example.net/b");
        },
        "Credentialed redirect URL was accepted");
    ExpectRejected(
        [] {
          ResolveRedirectURL("https://example.com/a", "http://example.com/b");
        },
        "HTTPS downgrade was accepted");
    ExpectRejected(
        [] { ResolveRedirectURL("http://example.com:/a", "/b"); },
        "Empty explicit port was accepted");
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
