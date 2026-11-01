// Build the UTF-8 Windows entry point with the application's CRT toolchain.
// Prebuilt Qt MinGW entry points may refer to MSVCRT globals absent in UCRT.
#include <windows.h>
#include <shellapi.h>

#include <vector>

int qMain(int argc, char **argv);

namespace
{
    int runApplication()
    {
        int argc = 0;
        wchar_t **wide = CommandLineToArgvW(GetCommandLineW(), &argc);
        if (!wide)
            return 1;
        std::vector<std::vector<char>> arguments;
        arguments.reserve(argc);
        for (int i = 0; i < argc; ++i)
        {
            const int size = WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, nullptr, 0, nullptr, nullptr);
            if (size <= 0)
            {
                LocalFree(wide);
                return 1;
            }
            arguments.emplace_back(size);
            if (!WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, arguments.back().data(), size, nullptr, nullptr))
            {
                LocalFree(wide);
                return 1;
            }
        }
        LocalFree(wide);
        std::vector<char *> argv;
        argv.reserve(argc + 1);
        for (auto &argument : arguments)
            argv.push_back(argument.data());
        argv.push_back(nullptr);
        return qMain(argc, argv.data());
    }
}

extern "C" int WINAPI WinMain(HINSTANCE, HINSTANCE, LPSTR, int)
{
    return runApplication();
}

extern "C" int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int)
{
    return runApplication();
}
