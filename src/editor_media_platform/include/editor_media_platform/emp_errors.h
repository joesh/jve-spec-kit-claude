#pragma once

#include <string>
#include <variant>

namespace emp {

// EMP-owned error codes (no FFmpeg codes escape)
enum class ErrorCode {
    Ok,
    FileNotFound,
    Unsupported,
    DecodeFailed,
    SeekFailed,
    EOFReached,
    InvalidArg,
    Internal
};

// Convert error code to string (for Lua binding)
inline const char* error_code_to_string(ErrorCode code) {
    switch (code) {
        case ErrorCode::Ok:           return "Ok";
        case ErrorCode::FileNotFound: return "FileNotFound";
        case ErrorCode::Unsupported:  return "Unsupported";
        case ErrorCode::DecodeFailed: return "DecodeFailed";
        case ErrorCode::SeekFailed:   return "SeekFailed";
        case ErrorCode::EOFReached:   return "EOFReached";
        case ErrorCode::InvalidArg:   return "InvalidArg";
        case ErrorCode::Internal:     return "Internal";
    }
    return "Unknown";
}

// Error with context message
struct Error {
    ErrorCode code;
    std::string message;

    static Error ok() { return {ErrorCode::Ok, ""}; }
    static Error file_not_found(const std::string& path) {
        return {ErrorCode::FileNotFound, "File not found: " + path};
    }
    static Error unsupported(const std::string& detail) {
        return {ErrorCode::Unsupported, detail};
    }
    static Error decode_failed(const std::string& detail) {
        return {ErrorCode::DecodeFailed, detail};
    }
    static Error seek_failed(const std::string& detail) {
        return {ErrorCode::SeekFailed, detail};
    }
    static Error eof() {
        return {ErrorCode::EOFReached, "End of file reached"};
    }
    static Error invalid_arg(const std::string& detail) {
        return {ErrorCode::InvalidArg, detail};
    }
    static Error internal(const std::string& detail) {
        return {ErrorCode::Internal, detail};
    }
};

// Result type: either value T or Error
template<typename T>
class Result {
public:
    // Success constructor
    Result(T value) : m_data(std::move(value)) {}

    // Error constructor
    Result(Error error) : m_data(std::move(error)) {}

    bool is_ok() const { return std::holds_alternative<T>(m_data); }
    bool is_error() const { return std::holds_alternative<Error>(m_data); }

    // Access value (asserts if error)
    T& value() { return std::get<T>(m_data); }
    const T& value() const { return std::get<T>(m_data); }

    // Access error (asserts if ok)
    Error& error() { return std::get<Error>(m_data); }
    const Error& error() const { return std::get<Error>(m_data); }

    // Unwrap value or throw (for convenience)
    T unwrap() {
        if (is_error()) {
            throw std::runtime_error(error().message);
        }
        return std::move(value());
    }

private:
    std::variant<T, Error> m_data;
};

// Specialization for void result
template<>
class Result<void> {
public:
    Result() : m_error(std::nullopt) {}
    Result(Error error) : m_error(std::move(error)) {}

    bool is_ok() const { return !m_error.has_value(); }
    bool is_error() const { return m_error.has_value(); }

    Error& error() { return *m_error; }
    const Error& error() const { return *m_error; }

private:
    std::optional<Error> m_error;
};

} // namespace emp
