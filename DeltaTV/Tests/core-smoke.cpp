// DeltaTV's original, synthetic smoke cartridge contains no commercial ROM or boot logo.
// Tests the actual pinned Gambatte CPU/PPU/APU and GBCInputGetter, not a mock core.
#include "gambatte.h"
#include "GBCInputGetter.h"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <memory>
#include <chrono>
#include <sys/stat.h>

namespace {
void require(bool condition, const std::string &message)
{
    if (!condition) { throw std::runtime_error(message); }
}

void writeCartridge(const std::string &path, bool color, unsigned char cartridgeType = 0x03, bool lcdEnabled = true)
{
    std::vector<unsigned char> rom(32768, 0);
    rom[0x100] = 0xC3; rom[0x101] = 0x50; rom[0x102] = 0x01; // JP $0150
    const std::string title = "DELTA TV SMOKE";
    std::copy(title.begin(), title.end(), rom.begin() + 0x134);
    rom[0x143] = color ? 0x80 : 0x00;
    rom[0x147] = cartridgeType;
    rom[0x149] = 0x02; // 8 KiB cartridge RAM

    // Disable interrupts/LCD, enable cartridge RAM, write a known save byte,
    // turn on channel 1, re-enable LCD, and mirror joypad state to save RAM.
    std::vector<unsigned char> code = {
        0xF3, 0x31, 0xFE, 0xFF,
        0xAF, 0xE0, 0x40,
        0x3E, 0x0A, 0xEA, 0x00, 0x00,
        0x3E, 0x5A, 0xEA, 0x00, 0xA0,
        0x3E, 0x80, 0xE0, 0x26,
        0x3E, 0x77, 0xE0, 0x24,
        0x3E, 0x11, 0xE0, 0x25,
        0x3E, 0x80, 0xE0, 0x11,
        0x3E, 0xF3, 0xE0, 0x12,
        0xAF, 0xE0, 0x13,
        0x3E, 0xC3, 0xE0, 0x14,
        0x3E, 0xE4, 0xE0, 0x47,
        0x3E, 0x91, 0xE0, 0x40
    };
    if (!lcdEnabled) { code[code.size() - 3] = 0; }
    const unsigned loop = 0x150 + static_cast<unsigned>(code.size());
    const unsigned char inputLoop[] = {
        0x3E, 0x10, 0xE0, 0x00, 0x00, 0xF0, 0x00, 0xEA, 0x01, 0xA0,
        0xC3, static_cast<unsigned char>(loop & 0xFF), static_cast<unsigned char>(loop >> 8)
    };
    code.insert(code.end(), std::begin(inputLoop), std::end(inputLoop));
    std::copy(code.begin(), code.end(), rom.begin() + 0x150);
    unsigned char checksum = 0;
    for (unsigned i = 0x134; i <= 0x14C; ++i) { checksum = checksum - rom[i] - 1; }
    rom[0x14D] = checksum;
    unsigned sum = 0;
    for (unsigned i = 0; i < rom.size(); ++i) { sum += rom[i]; }
    rom[0x14E] = (sum >> 8) & 0xFF;
    rom[0x14F] = sum & 0xFF;
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char *>(rom.data()), rom.size());
    require(static_cast<bool>(output), "Could not create synthetic cartridge");
}

std::vector<unsigned char> readFile(const std::string &path)
{
    std::ifstream file(path, std::ios::binary);
    require(static_cast<bool>(file), "Missing output: " + path);
    return std::vector<unsigned char>(std::istreambuf_iterator<char>(file), {});
}

void testCartridge(const std::string &directory, bool color)
{
    const std::string stem = directory + (color ? "/synthetic-color" : "/synthetic-mono");
    const std::string romPath = stem + (color ? ".gbc" : ".gb");
    writeCartridge(romPath, color);

    GBCInputGetter input;
    gambatte::GB core;
    core.setInputGetter(&input);
    core.setSaveDir(directory);
    require(core.load(romPath, gambatte::GB::MULTICART_COMPAT) == 0, "Cartridge load failed");
    require(core.isLoaded() && core.isCgb() == color, "Wrong Game Boy hardware mode");

    std::vector<gambatte::uint_least32_t> video(160 * 144, 0xAABBCCDD);
    std::vector<gambatte::uint_least32_t> audio(35112 + 2064, 0);
    unsigned frames = 0;
    bool heardAudio = false;
    const auto run = [&]() {
        for (unsigned call = 0; call < 12; ++call)
        {
            std::size_t samples = 35112;
            const auto result = core.runFor(video.data(), 160, audio.data(), samples);
            require(samples <= audio.size(), "Core exceeded audio buffer capacity");
            if (result >= 0) { ++frames; }
            heardAudio |= std::any_of(audio.begin(), audio.begin() + samples,
                [](gambatte::uint_least32_t sample) { return sample != 0; });
        }
    };

    input.activateInput(gambatte::InputGetter::A);
    require(input.inputs() == gambatte::InputGetter::A, "Input activation failed");
    run();
    core.saveSavedata();
    const auto pressed = readFile(stem + ".sav");
    require(pressed.size() == 8192 && pressed[0] == 0x5A, "CPU did not write battery RAM");
    require((pressed[1] & 1) == 0, "Emulated joypad did not receive A press");
    require(frames > 0, "PPU did not produce a video frame");
    require(std::any_of(video.begin(), video.end(), [](gambatte::uint_least32_t pixel) {
        return pixel != 0xAABBCCDD;
    }), "PPU did not write the video buffer");
    require(heardAudio, "APU did not produce non-silent audio samples");

    const std::string statePath = stem + ".state";
    require(core.saveState(nullptr, 0, statePath), "Save-state creation failed");
    input.deactivateInput(gambatte::InputGetter::A);
    run();
    core.saveSavedata();
    const auto released = readFile(stem + ".sav");
    require((released[1] & 1) != 0, "Emulated joypad did not receive A release");
    require(core.loadState(statePath), "Save-state restore failed");
    core.saveSavedata();
    require(readFile(stem + ".sav") == pressed, "Save-state restore did not restore battery RAM");
    require(!core.saveState(nullptr, 0, directory + "/missing-directory/state"),
        "An unwritable save-state destination was reported as successful");
    require(!core.loadState(directory + "/missing.state"), "A missing save state was accepted");
    const std::string invalidStatePath = stem + ".invalid-state";
    {
        std::ofstream invalidState(invalidStatePath, std::ios::binary);
        invalidState << "not a Gambatte state";
    }
    require(!core.loadState(invalidStatePath), "An invalid save state was accepted");
    input.resetInputs();
    require(input.inputs() == 0, "Input reset failed");
    std::cout << (color ? "GBC" : "GB")
              << ": cartridge, CPU, video, audio, controller press/release, battery save, state restore, state errors passed\n";
}

void writeBytes(const std::string &path, const std::vector<unsigned char> &bytes)
{
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    require(static_cast<bool>(output), "Could not write test save");
}

void testIsolatedSessions(const std::string &directory)
{
    const std::string first = directory + "/first";
    const std::string second = directory + "/second";
    const std::string restored = directory + "/restored";
    for (const auto &path : {first, second, restored})
    {
        require(mkdir(path.c_str(), 0700) == 0, "Could not create session directory");
        writeCartridge(path + "/game.gb", false, 0x10); // MBC3 + RAM + RTC + battery
    }
    const std::vector<unsigned char> savedRAM(8192, 0xA7);
    const std::vector<unsigned char> savedRTC = {0x60, 0x01, 0x02, 0x03};
    writeBytes(first + "/game.sav", savedRAM);
    writeBytes(first + "/game.rtc", savedRTC);

    GBCInputGetter input;
    auto core = std::make_unique<gambatte::GB>();
    core->setInputGetter(&input);
    core->setSaveDir(first);
    require(core->load(first + "/game.gb") == 0, "First session load failed");
    core->saveSavedata();
    require(readFile(first + "/game.sav") == savedRAM, "First session RAM restore failed");
    require(readFile(first + "/game.rtc") == savedRTC, "First session RTC restore failed");

    // Same ROM basename, absent second save. Destruct the old core BEFORE
    // selecting the new directory, exactly like the bridge's session boundary.
    core.reset();
    core = std::make_unique<gambatte::GB>();
    core->setInputGetter(&input);
    core->setSaveDir(second);
    require(core->load(second + "/game.gb") == 0, "Second session load failed");
    core->saveSavedata();
    require(readFile(second + "/game.sav") != savedRAM, "Second session inherited previous battery RAM");
    require(readFile(second + "/game.rtc") != savedRTC, "Second session inherited previous RTC");
    require(readFile(first + "/game.sav") == savedRAM, "Switching sessions overwrote previous save");
    core.reset();

    writeBytes(restored + "/game.sav", readFile(first + "/game.sav"));
    writeBytes(restored + "/game.rtc", readFile(first + "/game.rtc"));
    core = std::make_unique<gambatte::GB>();
    core->setSaveDir(restored);
    require(core->load(restored + "/game.gb") == 0, "Restored session load failed");
    core->saveSavedata();
    require(readFile(restored + "/game.sav") == savedRAM, "Battery roundtrip failed");
    require(readFile(restored + "/game.rtc") == savedRTC, "RTC roundtrip failed");
    std::cout << "Same-basename session isolation and SAV+RTC roundtrip passed\n";
}

void testLCDDisabled(const std::string &directory)
{
    const auto path = directory + "/lcd-disabled.gb";
    writeCartridge(path, false, 0x03, false);
    gambatte::GB core;
    GBCInputGetter input;
    core.setInputGetter(&input);
    require(core.load(path) == 0, "LCD-disabled cartridge load failed");
    std::vector<gambatte::uint_least32_t> video(160 * 144);
    std::vector<gambatte::uint_least32_t> audio(35112 + 2064);
    const auto start = std::chrono::steady_clock::now();
    for (unsigned callback = 0; callback < 8; ++callback)
    {
        std::size_t samples = 35112;
        // One runFor per callback. Never wait in a loop for video readiness.
        core.runFor(video.data(), 160, audio.data(), samples);
        require(samples > 0 && samples <= audio.size(), "LCD-off audio budget was invalid");
    }
    const auto elapsed = std::chrono::steady_clock::now() - start;
    require(elapsed < std::chrono::seconds(5), "LCD-off callbacks did not return promptly");
    std::cout << "LCD-disabled cartridge bounded callbacks passed\n";
}
}

int main(int argc, char **argv)
{
    try
    {
        require(argc == 2, "Usage: core-smoke TEMP_DIRECTORY");
        testCartridge(argv[1], false);
        testCartridge(argv[1], true);
        testIsolatedSessions(argv[1]);
        testLCDDisabled(argv[1]);
        gambatte::GB invalid;
        require(invalid.load(std::string(argv[1]) + "/missing.gb") < 0, "Missing ROM was accepted");
        std::cout << "Missing cartridge rejection passed\n";
    }
    catch (const std::exception &error)
    {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
