#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

// LZSS decompressor derived from zssdec by Willem Hengeveld.
class LzssDecompressor {
    enum State { CopyFromDictionary, ExpectingFlag, ProcessFlagBit, ExpectingSecondByte };

public:
    LzssDecompressor()
        : state_(ExpectingFlag),
          flags_(0),
          bit_number_(0),
          source_(nullptr),
          source_end_(nullptr),
          destination_(nullptr),
          destination_end_(nullptr),
          first_byte_(0),
          dictionary_(DictionarySize + MaximumMatch - 1, ' '),
          dictionary_position_(DictionarySize - MaximumMatch),
          copy_position_(0),
          copy_count_(0) {}

    void decompress(uint8_t* destination,
                    uint32_t destination_length,
                    uint32_t* destination_used,
                    uint8_t* source,
                    uint32_t source_length,
                    uint32_t* source_used) {
        source_ = source;
        source_end_ = source + source_length;
        destination_ = destination;
        destination_end_ = destination + destination_length;

        while (source_ < source_end_ && destination_ < destination_end_) {
            switch (state_) {
                case ExpectingFlag:
                    flags_ = *source_++;
                    bit_number_ = 0;
                    state_ = ProcessFlagBit;
                    break;
                case ProcessFlagBit:
                    if (flags_ & 1) {
                        if (source_ >= source_end_) {
                            break;
                        }
                        *destination_++ = *source_++;
                        addToDictionary(destination_[-1]);
                    } else {
                        if (source_ >= source_end_) {
                            break;
                        }
                        first_byte_ = *source_++;
                        state_ = ExpectingSecondByte;
                        continue;
                    }
                    nextFlagBit();
                    break;
                case ExpectingSecondByte:
                    if (source_ >= source_end_) {
                        break;
                    }
                    setCopyCounter(first_byte_, *source_++);
                    state_ = CopyFromDictionary;
                    break;
                case CopyFromDictionary:
                    while (destination_ < destination_end_ && copy_count_) {
                        *destination_++ = dictionary_[copy_position_];
                        addToDictionary(dictionary_[copy_position_]);
                        copy_position_ = (copy_position_ + 1) & (DictionarySize - 1);
                        --copy_count_;
                    }
                    if (!copy_count_) {
                        nextFlagBit();
                    }
                    break;
            }
        }

        if (destination_used) {
            *destination_used = static_cast<uint32_t>(destination_ - destination);
        }
        if (source_used) {
            *source_used = static_cast<uint32_t>(source_ - source);
        }
    }

    void flush(uint8_t* destination, uint32_t destination_length, uint32_t* destination_used) {
        destination_ = destination;
        destination_end_ = destination + destination_length;
        if (state_ == CopyFromDictionary) {
            while (destination_ < destination_end_ && copy_count_) {
                *destination_++ = dictionary_[copy_position_];
                addToDictionary(dictionary_[copy_position_]);
                copy_position_ = (copy_position_ + 1) & (DictionarySize - 1);
                --copy_count_;
            }
        }
        if (destination_used) {
            *destination_used = static_cast<uint32_t>(destination_ - destination);
        }
    }

private:
    enum { DictionarySize = 4096, MaximumMatch = 18, CopyThreshold = 3 };

    void addToDictionary(uint8_t value) {
        dictionary_[dictionary_position_++] = value;
        dictionary_position_ &= DictionarySize - 1;
    }

    void nextFlagBit() {
        ++bit_number_;
        flags_ >>= 1;
        state_ = bit_number_ == 8 ? ExpectingFlag : ProcessFlagBit;
    }

    void setCopyCounter(uint8_t first, uint8_t second) {
        copy_position_ = first | ((second & 0xf0) << 4);
        copy_count_ = CopyThreshold + (second & 0x0f);
    }

    State state_;
    uint8_t flags_;
    int bit_number_;
    uint8_t* source_;
    uint8_t* source_end_;
    uint8_t* destination_;
    uint8_t* destination_end_;
    uint8_t first_byte_;
    std::vector<uint8_t> dictionary_;
    int dictionary_position_;
    int copy_position_;
    int copy_count_;
};

struct PatchProfile {
    std::string name;
    std::vector<uint8_t> pattern;
    std::vector<uint8_t> replacement;
    bool validate_following_byte;
};

static PatchProfile profileForName(const std::string& name) {
    if (name == "ios5") {
        return {name,
                {0x67, 0xd0, 0x40, 0xf6},
                {0x00, 0x20, 0x40, 0xf6},
                false};
    }
    if (name == "ios6-7") {
        return {name,
                {0xb0, 0xf5, 0xfa, 0x6f, 0x00, 0xf0, 0x00, 0x00},
                {0xb0, 0xf5, 0xfa, 0x6f, 0x0c, 0x46, 0x0c, 0x46},
                true};
    }
    return {};
}

static std::vector<size_t> findMatches(const std::vector<uint8_t>& data,
                                       const PatchProfile& profile) {
    std::vector<size_t> matches;
    if (profile.pattern.empty() || data.size() < profile.pattern.size()) {
        return matches;
    }

    for (size_t offset = 0; offset <= data.size() - profile.pattern.size(); ++offset) {
        bool matches_pattern = false;
        if (profile.validate_following_byte) {
            matches_pattern =
                std::memcmp(&data[offset], profile.pattern.data(), 6) == 0 &&
                (data[offset + 6] == 0x92 || data[offset + 6] == 0xa2 ||
                 data[offset + 6] == 0x82);
        } else {
            matches_pattern =
                std::memcmp(&data[offset], profile.pattern.data(), profile.pattern.size()) == 0;
        }
        if (matches_pattern) {
            matches.push_back(offset);
        }
    }
    return matches;
}

static bool applyUniquePatch(std::vector<uint8_t>& data,
                             const PatchProfile& profile,
                             size_t* patched_offset) {
    const std::vector<size_t> matches = findMatches(data, profile);
    if (matches.size() != 1) {
        std::cerr << "Expected exactly one " << profile.name << " IOAESAccelerator pattern; found "
                  << matches.size() << ".\n";
        return false;
    }

    *patched_offset = matches[0];
    std::copy(profile.replacement.begin(),
              profile.replacement.end(),
              data.begin() + static_cast<std::ptrdiff_t>(*patched_offset));
    return true;
}

static bool runSelfTest() {
    const std::vector<std::string> profile_names = {"ios5", "ios6-7"};
    for (const std::string& name : profile_names) {
        const PatchProfile profile = profileForName(name);
        std::vector<uint8_t> data(64, 0xaa);
        std::copy(profile.pattern.begin(), profile.pattern.end(), data.begin() + 16);
        if (profile.validate_following_byte) {
            data[22] = 0x92;
        }

        size_t offset = 0;
        if (!applyUniquePatch(data, profile, &offset) || offset != 16 ||
            !std::equal(profile.replacement.begin(), profile.replacement.end(), data.begin() + 16)) {
            return false;
        }

        std::vector<uint8_t> duplicate_data(64, 0xaa);
        std::copy(profile.pattern.begin(), profile.pattern.end(), duplicate_data.begin() + 8);
        std::copy(profile.pattern.begin(), profile.pattern.end(), duplicate_data.begin() + 40);
        if (profile.validate_following_byte) {
            duplicate_data[14] = 0x92;
            duplicate_data[46] = 0x92;
        }
        if (findMatches(duplicate_data, profile).size() != 2) {
            std::cerr << "Duplicate-match rejection failed for profile " << name << ".\n";
            return false;
        }
    }
    std::cout << "aespatched self-test passed.\n";
    return true;
}

int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--self-test") {
        return runSelfTest() ? 0 : 1;
    }
    if (argc != 4) {
        std::cerr << "Usage: " << argv[0] << " <ios5|ios6-7> <input_kernelcache> <output_file>\n";
        return 1;
    }

    const PatchProfile profile = profileForName(argv[1]);
    if (profile.name.empty()) {
        std::cerr << "Unknown patch profile: " << argv[1] << "\n";
        return 1;
    }

    std::ifstream input_stream(argv[2], std::ios::binary);
    if (!input_stream) {
        std::cerr << "Cannot open: " << argv[2] << "\n";
        return 1;
    }
    std::vector<uint8_t> input((std::istreambuf_iterator<char>(input_stream)), {});
    input_stream.close();

    const std::vector<uint8_t> macho_magic = {0xce, 0xfa, 0xed, 0xfe};
    const std::vector<uint8_t>::iterator macho =
        std::search(input.begin(), input.end(), macho_magic.begin(), macho_magic.end());
    if (macho == input.end() || macho == input.begin()) {
        std::cerr << "Mach-O signature not found in compressed kernelcache.\n";
        return 1;
    }

    const size_t lzss_offset = static_cast<size_t>(macho - input.begin()) - 1;
    std::cout << "Profile " << profile.name << ": found Mach-O marker at 0x" << std::hex
              << (lzss_offset + 1) << ", decompressing from 0x" << lzss_offset << ".\n";

    std::vector<uint8_t> compressed(input.begin() + static_cast<std::ptrdiff_t>(lzss_offset),
                                    input.end());
    std::vector<uint8_t> decompressed(20 * 1024 * 1024);
    LzssDecompressor decompressor;
    uint32_t destination_used = 0;
    uint32_t source_used = 0;
    decompressor.decompress(decompressed.data(),
                            static_cast<uint32_t>(decompressed.size()),
                            &destination_used,
                            compressed.data(),
                            static_cast<uint32_t>(compressed.size()),
                            &source_used);
    uint32_t flushed = 0;
    decompressor.flush(decompressed.data() + destination_used,
                       static_cast<uint32_t>(decompressed.size() - destination_used),
                       &flushed);
    decompressed.resize(destination_used + flushed);
    if (decompressed.size() < 4) {
        std::cerr << "Kernelcache decompression produced no usable output.\n";
        return 1;
    }

    size_t patched_offset = 0;
    if (!applyUniquePatch(decompressed, profile, &patched_offset)) {
        return 1;
    }
    std::cout << "Patched " << profile.name << " IOAESAccelerator at offset 0x" << std::hex
              << patched_offset << ".\n";

    std::ofstream output_stream(argv[3], std::ios::binary);
    if (!output_stream) {
        std::cerr << "Cannot write: " << argv[3] << "\n";
        return 1;
    }
    output_stream.write(reinterpret_cast<const char*>(decompressed.data()),
                        static_cast<std::streamsize>(decompressed.size()));
    if (!output_stream) {
        std::cerr << "Failed while writing: " << argv[3] << "\n";
        return 1;
    }
    std::cout << "Patched kernelcache saved to " << argv[3] << ".\n";
    return 0;
}
