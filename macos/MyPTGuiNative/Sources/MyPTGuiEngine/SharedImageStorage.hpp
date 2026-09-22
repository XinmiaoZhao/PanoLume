#pragma once

#include <cstddef>
#include <memory>
#include <utility>
#include <vector>

namespace panolume {

/// Copying an image shares its immutable sample storage. Mutating operations
/// detach, so metadata copies and render/cache handles no longer duplicate a
/// full RGB frame merely because `NativeImage` is passed by value.
class SharedFloatPixels {
public:
    SharedFloatPixels() : storage_(std::make_shared<std::vector<float>>()) {}

    bool empty() const { return storage_->empty(); }
    std::size_t size() const { return storage_->size(); }
    const float *data() const { return storage_->data(); }
    float *data() { detach(); return storage_->data(); }

    const float &operator[](std::size_t index) const { return (*storage_)[index]; }
    float &operator[](std::size_t index) { detach(); return (*storage_)[index]; }

    operator const std::vector<float> &() const { return *storage_; }

    void clear() { storage_ = std::make_shared<std::vector<float>>(); }
    void shrink_to_fit() {
        if (storage_.use_count() == 1) {
            storage_->shrink_to_fit();
        }
    }

    void assign(std::size_t count, float value) {
        storage_ = std::make_shared<std::vector<float>>(count, value);
    }

    template <typename Iterator>
    void assign(Iterator first, Iterator last) {
        storage_ = std::make_shared<std::vector<float>>(first, last);
    }

    void swap(std::vector<float> &other) {
        std::vector<float> previous;
        if (storage_.use_count() == 1) {
            previous.swap(*storage_);
        }
        storage_ = std::make_shared<std::vector<float>>();
        storage_->swap(other);
        other.swap(previous);
    }

    long use_count() const { return storage_.use_count(); }

private:
    void detach() {
        if (storage_.use_count() != 1) {
            storage_ = std::make_shared<std::vector<float>>(*storage_);
        }
    }

    std::shared_ptr<std::vector<float>> storage_;
};

} // namespace panolume
