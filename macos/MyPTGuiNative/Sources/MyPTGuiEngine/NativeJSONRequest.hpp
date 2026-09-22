#pragma once

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace panolume {

class JSONRequest {
public:
    struct Impl;
    JSONRequest();
    explicit JSONRequest(const std::string &json);

    bool valid() const;
    const std::string &error() const;
    bool has(const std::string &key) const;
    std::string string(const std::string &key, const std::string &fallback = "") const;
    double number(const std::string &key, double fallback = 0.0) const;
    int integer(const std::string &key, int fallback = 0) const;
    bool boolean(const std::string &key, bool fallback = false) const;
    std::vector<std::string> string_array(const std::string &key) const;
    std::vector<double> number_array(const std::string &key) const;
    JSONRequest object(const std::string &key) const;
    std::vector<JSONRequest> object_array(const std::string &key) const;

private:
    explicit JSONRequest(std::shared_ptr<Impl> impl);
    std::shared_ptr<Impl> impl_;
};

// Owns one C-ABI request payload and its single structured parse. Engine
// entrypoints pass this typed value through the pipeline instead of repeatedly
// scanning or reparsing the original JSON text.
class EngineRequest {
public:
    explicit EngineRequest(const char *json)
        : source_(json ? json : ""), root_(source_) {}
    explicit EngineRequest(std::string json)
        : source_(std::move(json)), root_(source_) {}

    const std::string &source() const { return source_; }
    const JSONRequest &root() const { return root_; }
    bool valid() const { return root_.valid(); }
    const std::string &error() const { return root_.error(); }
    bool has(const std::string &key) const { return root_.has(key); }
    std::string string(const std::string &key, const std::string &fallback = "") const {
        return root_.string(key, fallback);
    }
    double number(const std::string &key, double fallback = 0.0) const {
        return root_.number(key, fallback);
    }
    int integer(const std::string &key, int fallback = 0) const {
        return root_.integer(key, fallback);
    }
    bool boolean(const std::string &key, bool fallback = false) const {
        return root_.boolean(key, fallback);
    }
    std::vector<std::string> string_array(const std::string &key) const {
        return root_.string_array(key);
    }
    std::vector<double> number_array(const std::string &key) const {
        return root_.number_array(key);
    }
    JSONRequest object(const std::string &key) const { return root_.object(key); }
    std::vector<JSONRequest> object_array(const std::string &key) const {
        return root_.object_array(key);
    }

private:
    std::string source_;
    JSONRequest root_;
};

bool engine_request_characterization_self_test();

} // namespace panolume
