#pragma once
// Minimal JSON value, parser and writer. Objects keep insertion order so output is deterministic.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace dharani::json {

class ParseError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

class Value;
using Array = std::vector<Value>;
using Object = std::vector<std::pair<std::string, Value>>;

class Value {
 public:
  Value() : v_(nullptr) {}
  Value(std::nullptr_t) : v_(nullptr) {}
  Value(bool b) : v_(b) {}
  Value(int x) : v_(static_cast<double>(x)) {}
  Value(std::int64_t x) : v_(static_cast<double>(x)) {}
  Value(std::uint64_t x) : v_(static_cast<double>(x)) {}
  Value(double x) : v_(x) {}
  Value(const char* s) : v_(std::string(s)) {}
  Value(std::string s) : v_(std::move(s)) {}
  Value(Array a) : v_(std::move(a)) {}
  Value(Object o) : v_(std::move(o)) {}

  static Value object() { return Value(Object{}); }
  static Value array() { return Value(Array{}); }

  bool is_null() const { return std::holds_alternative<std::nullptr_t>(v_); }
  bool is_bool() const { return std::holds_alternative<bool>(v_); }
  bool is_number() const { return std::holds_alternative<double>(v_); }
  bool is_string() const { return std::holds_alternative<std::string>(v_); }
  bool is_array() const { return std::holds_alternative<Array>(v_); }
  bool is_object() const { return std::holds_alternative<Object>(v_); }

  bool as_bool(bool fallback = false) const { return is_bool() ? std::get<bool>(v_) : fallback; }
  double as_number(double fallback = 0) const { return is_number() ? std::get<double>(v_) : fallback; }
  std::int64_t as_int(std::int64_t fallback = 0) const {
    return is_number() ? static_cast<std::int64_t>(std::llround(std::get<double>(v_))) : fallback;
  }
  const std::string& as_string() const {
    static const std::string empty;
    return is_string() ? std::get<std::string>(v_) : empty;
  }
  const Array& as_array() const {
    static const Array empty;
    return is_array() ? std::get<Array>(v_) : empty;
  }
  const Object& as_object() const {
    static const Object empty;
    return is_object() ? std::get<Object>(v_) : empty;
  }

  // Object access. get() returns a null Value for missing keys so lookups chain safely.
  const Value& get(std::string_view key) const {
    static const Value null_value;
    if (is_object()) {
      for (const auto& kv : std::get<Object>(v_)) {
        if (kv.first == key) return kv.second;
      }
    }
    return null_value;
  }
  bool has(std::string_view key) const { return !get(key).is_null(); }

  Value& set(std::string key, Value value) {
    if (!is_object()) v_ = Object{};
    auto& obj = std::get<Object>(v_);
    for (auto& kv : obj) {
      if (kv.first == key) {
        kv.second = std::move(value);
        return *this;
      }
    }
    obj.emplace_back(std::move(key), std::move(value));
    return *this;
  }
  Value& push(Value value) {
    if (!is_array()) v_ = Array{};
    std::get<Array>(v_).push_back(std::move(value));
    return *this;
  }

 private:
  std::variant<std::nullptr_t, bool, double, std::string, Array, Object> v_;
};

namespace detail {

class Parser {
 public:
  explicit Parser(std::string_view s) : s_(s) {}

  Value parse_document() {
    skip_ws();
    Value v = parse_value(0);
    skip_ws();
    if (i_ != s_.size()) fail("trailing characters");
    return v;
  }

 private:
  [[noreturn]] void fail(const char* msg) const {
    throw ParseError(std::string("json: ") + msg + " at offset " + std::to_string(i_));
  }
  void skip_ws() {
    while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\n' || s_[i_] == '\r' || s_[i_] == '\t')) ++i_;
  }
  char peek() const { return i_ < s_.size() ? s_[i_] : '\0'; }
  void expect(char c) {
    if (peek() != c) fail("unexpected character");
    ++i_;
  }
  bool match(std::string_view lit) {
    if (s_.substr(i_, lit.size()) == lit) {
      i_ += lit.size();
      return true;
    }
    return false;
  }

  Value parse_value(int depth) {
    if (depth > 64) fail("nesting too deep");
    switch (peek()) {
      case '{': return parse_object(depth);
      case '[': return parse_array(depth);
      case '"': return Value(parse_string());
      case 't':
        if (match("true")) return Value(true);
        break;
      case 'f':
        if (match("false")) return Value(false);
        break;
      case 'n':
        if (match("null")) return Value(nullptr);
        break;
      default:
        return parse_number();
    }
    fail("invalid literal");
  }

  Value parse_object(int depth) {
    expect('{');
    Object obj;
    skip_ws();
    if (peek() == '}') {
      ++i_;
      return Value(std::move(obj));
    }
    for (;;) {
      skip_ws();
      std::string key = parse_string();
      skip_ws();
      expect(':');
      skip_ws();
      obj.emplace_back(std::move(key), parse_value(depth + 1));
      skip_ws();
      if (peek() == ',') {
        ++i_;
        continue;
      }
      expect('}');
      return Value(std::move(obj));
    }
  }

  Value parse_array(int depth) {
    expect('[');
    Array arr;
    skip_ws();
    if (peek() == ']') {
      ++i_;
      return Value(std::move(arr));
    }
    for (;;) {
      skip_ws();
      arr.push_back(parse_value(depth + 1));
      skip_ws();
      if (peek() == ',') {
        ++i_;
        continue;
      }
      expect(']');
      return Value(std::move(arr));
    }
  }

  static void append_utf8(std::string& out, unsigned cp) {
    if (cp < 0x80) {
      out += static_cast<char>(cp);
    } else if (cp < 0x800) {
      out += static_cast<char>(0xC0 | (cp >> 6));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out += static_cast<char>(0xE0 | (cp >> 12));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
      out += static_cast<char>(0xF0 | (cp >> 18));
      out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }

  unsigned parse_hex4() {
    if (i_ + 4 > s_.size()) fail("truncated unicode escape");
    unsigned v = 0;
    for (int k = 0; k < 4; ++k) {
      char c = s_[i_++];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= static_cast<unsigned>(c - '0');
      else if (c >= 'a' && c <= 'f') v |= static_cast<unsigned>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v |= static_cast<unsigned>(c - 'A' + 10);
      else fail("bad unicode escape");
    }
    return v;
  }

  std::string parse_string() {
    expect('"');
    std::string out;
    for (;;) {
      if (i_ >= s_.size()) fail("unterminated string");
      char c = s_[i_++];
      if (c == '"') return out;
      if (c != '\\') {
        out += c;
        continue;
      }
      if (i_ >= s_.size()) fail("unterminated escape");
      char e = s_[i_++];
      switch (e) {
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case '/': out += '/'; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'u': {
          unsigned cp = parse_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF && match("\\u")) {
            unsigned lo = parse_hex4();
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          append_utf8(out, cp);
          break;
        }
        default: fail("bad escape");
      }
    }
  }

  Value parse_number() {
    std::size_t start = i_;
    if (peek() == '-') ++i_;
    while (i_ < s_.size() && ((s_[i_] >= '0' && s_[i_] <= '9') || s_[i_] == '.' || s_[i_] == 'e' ||
                              s_[i_] == 'E' || s_[i_] == '+' || s_[i_] == '-')) {
      ++i_;
    }
    if (i_ == start) fail("unexpected token");
    std::string token(s_.substr(start, i_ - start));
    char* end = nullptr;
    double d = std::strtod(token.c_str(), &end);
    if (end == nullptr || *end != '\0') fail("bad number");
    return Value(d);
  }

  std::string_view s_;
  std::size_t i_{0};
};

inline void dump_string(const std::string& s, std::string& out) {
  out += '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof buf, "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += '"';
}

inline void dump_value(const Value& v, std::string& out) {
  if (v.is_null()) {
    out += "null";
  } else if (v.is_bool()) {
    out += v.as_bool() ? "true" : "false";
  } else if (v.is_number()) {
    double d = v.as_number();
    char buf[40];
    if (!std::isfinite(d)) {
      out += "null";
    } else if (d == std::floor(d) && std::fabs(d) < 9e15) {
      std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(d));
      out += buf;
    } else {
      std::snprintf(buf, sizeof buf, "%.12g", d);
      out += buf;
    }
  } else if (v.is_string()) {
    dump_string(v.as_string(), out);
  } else if (v.is_array()) {
    out += '[';
    bool first = true;
    for (const auto& e : v.as_array()) {
      if (!first) out += ',';
      first = false;
      dump_value(e, out);
    }
    out += ']';
  } else {
    out += '{';
    bool first = true;
    for (const auto& kv : v.as_object()) {
      if (!first) out += ',';
      first = false;
      dump_string(kv.first, out);
      out += ':';
      dump_value(kv.second, out);
    }
    out += '}';
  }
}

}  // namespace detail

inline Value parse(std::string_view text) { return detail::Parser(text).parse_document(); }

inline std::string dump(const Value& v) {
  std::string out;
  detail::dump_value(v, out);
  return out;
}

}  // namespace dharani::json
