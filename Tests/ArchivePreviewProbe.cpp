#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <string>
#include "../NanaZip.UI.Modern/ArchivePreview.h"

static void Print(const std::wstring& value)
{
    int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0, nullptr, nullptr);
    std::string utf8(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), utf8.data(), size, nullptr, nullptr);
    fwrite(utf8.data(), 1, utf8.size(), stdout);
}

int wmain(int argc, wchar_t** argv)
{
    if (argc < 3) return 2;
    namespace P = NanaZip::ShellExtension::Preview;
    const auto result = P::Read(argv[2], argv[1], argc > 3 ? _wtoi64(argv[3]) : 350);
    const auto rows = P::Flatten(result);
    printf("%d\t%d\n", (int)result.State, rows.Truncated ? 1 : 0);
    for (const auto& row : rows.Items)
    {
        printf("%u\t%c\t", row.Depth, row.Directory ? 'D' : 'F');
        Print(row.Name);
        printf("\n");
    }
    return 0;
}
