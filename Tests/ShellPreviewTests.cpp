#define NOMINMAX
#include <windows.h>
#include <shlobj.h>
#include <cstdio>
#include <string>
#include <vector>

int wmain(int argc, wchar_t** argv)
{
    if (argc != 3) return 2;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HMODULE module = LoadLibraryExW(argv[1], nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!module) { printf("Shell LoadLibrary error: %lu\n", GetLastError()); return 3; }
    auto get = reinterpret_cast<HRESULT (STDAPICALLTYPE*)(REFCLSID, REFIID, void**)>(GetProcAddress(module,"DllGetClassObject"));
    const GUID clsid = {0x469d94e9,0x6af4,0x4395,{0xb3,0x96,0x99,0xb1,0x30,0x8f,0x8c,0xe5}};
    IClassFactory* factory = nullptr;
    if (!get || FAILED(get(clsid,IID_PPV_ARGS(&factory)))) return 4;
    IExplorerCommand* root = nullptr;
    HRESULT hr = factory->CreateInstance(nullptr,IID_PPV_ARGS(&root));
    factory->Release();
    if (FAILED(hr)) return 5;
    IShellItem* item = nullptr;
    IShellItemArray* selection = nullptr;
    if (FAILED(SHCreateItemFromParsingName(argv[2],nullptr,IID_PPV_ARGS(&item)))) return 6;
    SHCreateShellItemArrayFromShellItem(item,IID_PPV_ARGS(&selection)); item->Release();
    EXPCMDSTATE state = ECS_HIDDEN;
    // No archive I/O on the fast state query. Simulate Explorer's slow retry.
    if (root->GetState(selection,FALSE,&state) != E_PENDING) return 7;
    LPWSTR title = nullptr;
    if (FAILED(root->GetTitle(selection,&title))) return 8;
    CoTaskMemFree(title);
    // A host can enumerate before the slow result, then enumerate again.
    // That early query must not permanently suppress the preview.
    IEnumExplorerCommand* early = nullptr;
    if (FAILED(root->EnumSubCommands(&early))) return 15;
    early->Release();
    if (root->GetState(selection,TRUE,&state) != S_OK) return 9;
    IEnumExplorerCommand* enumerator = nullptr;
    if (FAILED(root->EnumSubCommands(&enumerator))) return 10;
    std::vector<std::wstring> names, icons;
    std::vector<unsigned> indents;
    for (;;)
    {
        IExplorerCommand* command = nullptr;
        ULONG fetched = 0;
        if (enumerator->Next(1,&command,&fetched) != S_OK || !fetched) break;
        EXPCMDFLAGS flags = ECF_DEFAULT;
        command->GetFlags(&flags);
        if (flags & ECF_ISSEPARATOR) { command->Release(); break; }
        title = nullptr;
        if (FAILED(command->GetTitle(selection,&title)) || !title) return 11;
        std::wstring name(title); CoTaskMemFree(title);
        command->GetState(selection,FALSE,&state);
        if (state != ECS_DISABLED || command->Invoke(selection,nullptr) != E_NOTIMPL) return 12;
        unsigned indent = 0;
        while (indent < name.size() && name[indent] == L'\x2002') ++indent;
        if (indent)
        {
            names.push_back(name.substr(indent)); indents.push_back(indent);
            LPWSTR icon = nullptr;
            if (FAILED(command->GetIcon(selection,&icon)) || !icon || !*icon) return 13;
            icons.push_back(icon); CoTaskMemFree(icon);
        }
        command->Release();
    }
    if (names.size() != 6 || names[0] != L"\u9879\u76ee" || names[2] != L"a.png" ||
        names[3] != L"setup.exe" || names[4] != L"\u8bf4\u660e.txt" ||
        indents != std::vector<unsigned>({2,4,6,4,2,2}) || icons[0] == icons[2]) return 14;
    enumerator->Release(); selection->Release(); root->Release();
    CoUninitialize();
    // The wrapper may hold a cached Modern module; process exit does the cleanup.
    printf("PASS: actual Shell COM menu rows, indentation, distinct folder/file icons, disabled preview and E_PENDING retry\n");
    return 0;
}
