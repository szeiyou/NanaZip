// Capture the real IExplorerCommand -> GUI boundary without showing dialogs.
#define NOMINMAX
#include <windows.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <cstdio>

#ifdef SHELL_GUI_CAPTURE
static bool Save(const std::wstring& path, const void* bytes, DWORD count)
{
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    bool ok = WriteFile(file, bytes, count, &written, nullptr) && written == count;
    CloseHandle(file); return ok;
}
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    wchar_t target[32768];
    if (!GetEnvironmentVariableW(L"NANAZIP_TEST_CAPTURE", target, ARRAYSIZE(target))) return 2;
    std::wstring command = GetCommandLineW();
    if (!Save(target, command.data(), static_cast<DWORD>(command.size() * sizeof(wchar_t)))) return 3;
    auto start = command.find(L" -ai#");
    if (start == std::wstring::npos) return 4;
    start += 5;
    auto colon = command.find(L':', start);
    auto end = command.find(L':', colon + 1);
    std::wstring name = command.substr(start, colon - start);
    DWORD size = std::stoul(command.substr(colon + 1, end - colon - 1));
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
    if (!mapping || size > 1024 * 1024) return 5;
    auto data = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, size);
    if (!data) return 6;
    bool ok = Save(std::wstring(target) + L".names", data, size);
    UnmapViewOfFile(data); CloseHandle(mapping);
    std::wstring eventName = command.substr(end + 1);
    HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, eventName.c_str());
    if (event) { SetEvent(event); CloseHandle(event); }
    return ok ? 0 : 7;
}
#else
int wmain(int argc, wchar_t** argv)
{
    if (argc < 4) return 2; // shell DLL, capture prefix, one or more archives
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool registeredHere = std::wstring(argv[1]) == L"--registered-here";
    HMODULE module = registeredHere ? nullptr : LoadLibraryExW(argv[1], nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!registeredHere && !module) return 3;
    auto get = module ? reinterpret_cast<HRESULT (STDAPICALLTYPE*)(REFCLSID, REFIID, void**)>(GetProcAddress(module, "DllGetClassObject")) : nullptr;
    const GUID clsid = {0x469d94e9,0x6af4,0x4395,{0xb3,0x96,0x99,0xb1,0x30,0x8f,0x8c,0xe5}};
    IClassFactory* factory = nullptr;
    HRESULT hr = registeredHere ? CoGetClassObject(clsid, CLSCTX_LOCAL_SERVER, nullptr, IID_PPV_ARGS(&factory)) :
        (get ? get(clsid, IID_PPV_ARGS(&factory)) : E_NOINTERFACE);
    if (FAILED(hr)) { printf("Shell activation failed: 0x%08lX\n", hr); return 4; }
    IExplorerCommand* root = nullptr;
    if (FAILED(factory->CreateInstance(nullptr, IID_PPV_ARGS(&root)))) return 5;
    factory->Release();
    std::vector<PIDLIST_ABSOLUTE> ids;
    for (int i = 3; i < argc; ++i) {
        PIDLIST_ABSOLUTE id = nullptr;
        if (FAILED(SHParseDisplayName(argv[i], nullptr, &id, 0, nullptr))) return 6;
        ids.push_back(id);
    }
    IShellItemArray* selection = nullptr;
    if (FAILED(SHCreateShellItemArrayFromIDLists(static_cast<UINT>(ids.size()), const_cast<PCIDLIST_ABSOLUTE*>(ids.data()), &selection))) return 7;
    for (auto id : ids) CoTaskMemFree(id);
    LPWSTR title = nullptr;
    if (FAILED(root->GetTitle(selection, &title))) return 8;
    CoTaskMemFree(title);
    IEnumExplorerCommand* enumerator = nullptr;
    if (FAILED(root->EnumSubCommands(&enumerator))) return 9;
    unsigned count = 0;
    for (;;) {
        IExplorerCommand* item = nullptr;
        ULONG fetched = 0;
        if (enumerator->Next(1, &item, &fetched) != S_OK || !fetched) break;
        title = nullptr;
        EXPCMDSTATE state = ECS_HIDDEN;
        item->GetState(selection, FALSE, &state);
        item->GetTitle(selection, &title);
        std::wstring name = title ? title : L"";
        CoTaskMemFree(title);
        // The retained GUI uses English fallback or the local Chinese resources.
        bool extract = name.rfind(L"Extract", 0) == 0 || name.rfind(L"\u63d0\u53d6", 0) == 0 || name.rfind(L"\u89e3\u538b", 0) == 0;
        if (registeredHere) extract = name == L"Extract Here" || name == L"\u63d0\u53d6\u5230\u5f53\u524d\u4f4d\u7f6e";
        if (state == ECS_ENABLED && extract) {
            std::wstring capture = std::wstring(argv[2]) + L"_" + std::to_wstring(++count);
            SetEnvironmentVariableW(L"NANAZIP_TEST_CAPTURE", capture.c_str());
            if (FAILED(item->Invoke(selection, nullptr))) return 10;
        }
        item->Release();
    }
    enumerator->Release(); selection->Release(); root->Release();
    CoUninitialize();
    if (count != (registeredHere ? 1u : 4u)) { printf("Unexpected extraction menu command count: %u\n", count); return 11; }
    printf("PASS: invoked %u actual extraction menu command(s)\n", count);
    return 0;
}
#endif
