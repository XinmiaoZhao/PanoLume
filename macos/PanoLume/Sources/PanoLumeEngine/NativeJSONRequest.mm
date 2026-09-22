#include "NativeJSONRequest.hpp"

#import <Foundation/Foundation.h>

#include <cmath>
#include <limits>

namespace panolume {

struct JSONRequest::Impl {
    id value = nil;
    bool isValid = false;
    std::string error;

    ~Impl() {
        value = nil;
    }
};

namespace {

id object_for_key(const std::shared_ptr<JSONRequest::Impl> &impl, const std::string &key) {
    if (!impl || !impl->isValid || ![impl->value isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *name = [[NSString alloc] initWithBytes:key.data()
                                              length:key.size()
                                            encoding:NSUTF8StringEncoding];
    NSDictionary *root = (NSDictionary *)impl->value;
    id direct = [root objectForKey:name];
    if (direct) {
        return direct;
    }
    // Swift request envelopes keep related settings typed and nested. The old
    // text scanner accidentally searched through those objects globally; keep
    // the intended compatibility explicitly while parsing the JSON only once.
    for (NSString *containerName in @[@"settings", @"exportSettings", @"poseAdjustment"]) {
        id container = [root objectForKey:containerName];
        if ([container isKindOfClass:[NSDictionary class]]) {
            id nested = [(NSDictionary *)container objectForKey:name];
            if (nested) {
                return nested;
            }
        }
    }
    return nil;
}

std::string utf8_string(id value, const std::string &fallback) {
    if (![value isKindOfClass:[NSString class]]) {
        return fallback;
    }
    const char *text = [(NSString *)value UTF8String];
    return text ? std::string(text) : fallback;
}

} // namespace

JSONRequest::JSONRequest() : impl_(std::make_shared<Impl>()) {}

JSONRequest::JSONRequest(const std::string &json) : impl_(std::make_shared<Impl>()) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:json.data() length:json.size()];
        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!parsed || error) {
            impl_->error = error
                ? std::string([[error localizedDescription] UTF8String] ?: "invalid JSON")
                : "invalid JSON";
            return;
        }
        impl_->value = parsed;
        impl_->isValid = true;
    }
}

JSONRequest::JSONRequest(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}

bool JSONRequest::valid() const { return impl_ && impl_->isValid; }

const std::string &JSONRequest::error() const {
    static const std::string empty;
    return impl_ ? impl_->error : empty;
}

bool JSONRequest::has(const std::string &key) const {
    return object_for_key(impl_, key) != nil;
}

std::string JSONRequest::string(const std::string &key, const std::string &fallback) const {
    return utf8_string(object_for_key(impl_, key), fallback);
}

double JSONRequest::number(const std::string &key, double fallback) const {
    id value = object_for_key(impl_, key);
    if (![value isKindOfClass:[NSNumber class]]) {
        return fallback;
    }
    const double number = [(NSNumber *)value doubleValue];
    return std::isfinite(number) ? number : fallback;
}

int JSONRequest::integer(const std::string &key, int fallback) const {
    const double value = number(key, static_cast<double>(fallback));
    if (value < static_cast<double>(std::numeric_limits<int>::min())
        || value > static_cast<double>(std::numeric_limits<int>::max())) {
        return fallback;
    }
    return static_cast<int>(std::llround(value));
}

bool JSONRequest::boolean(const std::string &key, bool fallback) const {
    id value = object_for_key(impl_, key);
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value boolValue] : fallback;
}

std::vector<std::string> JSONRequest::string_array(const std::string &key) const {
    std::vector<std::string> result;
    id value = object_for_key(impl_, key);
    if (![value isKindOfClass:[NSArray class]]) {
        return result;
    }
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSString class]]) {
            result.push_back(utf8_string(item, ""));
        }
    }
    return result;
}

std::vector<double> JSONRequest::number_array(const std::string &key) const {
    std::vector<double> result;
    id value = object_for_key(impl_, key);
    if (![value isKindOfClass:[NSArray class]]) {
        return result;
    }
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSNumber class]]) {
            const double number = [(NSNumber *)item doubleValue];
            if (std::isfinite(number)) {
                result.push_back(number);
            }
        }
    }
    return result;
}

JSONRequest JSONRequest::object(const std::string &key) const {
    id value = object_for_key(impl_, key);
    if (![value isKindOfClass:[NSDictionary class]]) {
        return JSONRequest();
    }
    std::shared_ptr<Impl> child = std::make_shared<Impl>();
    child->value = value;
    child->isValid = true;
    return JSONRequest(std::move(child));
}

std::vector<JSONRequest> JSONRequest::object_array(const std::string &key) const {
    std::vector<JSONRequest> result;
    id value = object_for_key(impl_, key);
    if (![value isKindOfClass:[NSArray class]]) {
        return result;
    }
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        std::shared_ptr<Impl> child = std::make_shared<Impl>();
        child->value = item;
        child->isValid = true;
        result.push_back(JSONRequest(std::move(child)));
    }
    return result;
}

bool engine_request_characterization_self_test() {
    EngineRequest request(R"JSON({
        "jobId": 42,
        "paths": ["a.nef", "b.nef"],
        "settings": {
            "previewMaxSide": 2400,
            "displayStretch": true,
            "projection": "equirectangular"
        },
        "controlPoints": [
            {"imageAIndex": 0, "imageBIndex": 1, "xA": 10.5, "xB": 12.5}
        ]
    })JSON");
    if (!request.valid()
        || request.integer("jobId", 0) != 42
        || request.integer("previewMaxSide", 0) != 2400
        || !request.boolean("displayStretch", false)
        || request.string("projection") != "equirectangular"
        || request.string_array("paths") != std::vector<std::string>({"a.nef", "b.nef"})) {
        return false;
    }
    const std::vector<JSONRequest> points = request.object_array("controlPoints");
    return points.size() == 1
        && points.front().integer("imageAIndex", -1) == 0
        && points.front().integer("imageBIndex", -1) == 1
        && std::abs(points.front().number("xA", 0.0) - 10.5) < 1e-12;
}

} // namespace panolume
