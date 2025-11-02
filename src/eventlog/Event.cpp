#include "jve/eventlog/Event.hpp"

#include <nlohmann/json.hpp>
#include <openssl/evp.h>

#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <vector>

using json = nlohmann::json;

namespace jve::eventlog {

Event parseEventJsonLine(const std::string& line) {
    json parsed = json::parse(line);
    Event event;
    event.id = parsed.at("id").get<std::string>();
    event.type = parsed.at("type").get<std::string>();
    event.scope = parsed.value("scope", "");
    event.timestampMs = parsed.value("ts", 0LL);
    event.author = parsed.value("author", "");
    if (parsed.contains("parents")) {
        event.parents = parsed.at("parents").get<std::vector<std::string>>();
    }
    event.schemaVersion = parsed.value("schema", 1);
    event.payloadVersion = parsed.value("payload_v", 1);
    if (parsed.contains("payload")) {
        event.payloadJson = parsed.at("payload").dump();
    }
    return event;
}

std::string sha256Hex(const std::string& input) {
    const EVP_MD* md = EVP_sha256();
    if (md == nullptr) {
        throw std::runtime_error("EVP_sha256 unavailable");
    }

    EVP_MD_CTX* context = EVP_MD_CTX_new();
    if (context == nullptr) {
        throw std::runtime_error("Failed to allocate EVP_MD_CTX");
    }

    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int hash_length = 0;

    if (EVP_DigestInit_ex(context, md, nullptr) != 1 ||
        EVP_DigestUpdate(context, input.data(), input.size()) != 1 ||
        EVP_DigestFinal_ex(context, hash, &hash_length) != 1) {
        EVP_MD_CTX_free(context);
        throw std::runtime_error("Failed to compute SHA-256 digest");
    }
    EVP_MD_CTX_free(context);

    std::ostringstream oss;
    for (unsigned int i = 0; i < hash_length; ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(hash[i]);
    }
    return oss.str();
}

}  // namespace jve::eventlog
