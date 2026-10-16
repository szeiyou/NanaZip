#define NOMINMAX
#include <windows.h>
#include <algorithm>
#include <memory>
#include "ArchivePreview.h"
#include "../NanaZip.Core/SevenZip/CPP/Common/MyInitGuid.h"
#include "../NanaZip.Core/SevenZip/CPP/7zip/Archive/IArchive.h"

namespace NanaZip::ShellExtension::Preview
{
    namespace
    {
        constexpr unsigned MaximumItems = 10000;
        constexpr unsigned MaximumNodes = 20000;
        constexpr UInt64 MaximumRead = 16ull << 20;
        constexpr UInt64 MaximumMemory = 32ull << 20;

        struct Budget
        {
            ULONGLONG Deadline;
            UInt64 Bytes = 0;
            bool Limited = false;
            bool Check()
            {
                Limited = Limited || GetTickCount64() >= Deadline;
                return !Limited;
            }
        };

        class Input final : public IInStream
        {
            HANDLE File;
            Budget& Limit;
        public:
            Input(HANDLE file, Budget& limit) : File(file), Limit(limit) {}
            STDMETHODIMP QueryInterface(REFIID iid, void** out) throw() override
            {
                *out = nullptr;
                if (iid != IID_IUnknown && iid != IID_IInStream && iid != IID_ISequentialInStream) return E_NOINTERFACE;
                *out = static_cast<IInStream*>(this); AddRef(); return S_OK;
            }
            STDMETHODIMP_(ULONG) AddRef() throw() override { return 2; }
            STDMETHODIMP_(ULONG) Release() throw() override { return 1; }
            STDMETHODIMP Read(void* data, UInt32 size, UInt32* processed) throw() override
            {
                if (processed) *processed = 0;
                if (!Limit.Check()) return E_ABORT;
                if (size > MaximumRead - Limit.Bytes) { Limit.Limited = true; return E_ABORT; }
                DWORD count = 0;
                if (!ReadFile(File, data, size, &count, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
                Limit.Bytes += count;
                if (processed) *processed = count;
                return Limit.Check() ? S_OK : E_ABORT;
            }
            STDMETHODIMP Seek(Int64 offset, UInt32 origin, UInt64* position) throw() override
            {
                if (!Limit.Check()) return E_ABORT;
                if (origin > FILE_END) return E_INVALIDARG;
                LARGE_INTEGER distance, result;
                distance.QuadPart = offset;
                if (!SetFilePointerEx(File, distance, &result, origin)) return HRESULT_FROM_WIN32(GetLastError());
                if (position) *position = result.QuadPart;
                return S_OK;
            }
        };

        class Callback final : public IArchiveOpenCallback, public IArchiveRequestMemoryUseCallback
        {
            Budget& Limit;
        public:
            explicit Callback(Budget& limit) : Limit(limit) {}
            STDMETHODIMP QueryInterface(REFIID iid, void** out) throw() override
            {
                *out = nullptr;
                if (iid == IID_IUnknown || iid == IID_IArchiveOpenCallback)
                    *out = static_cast<IArchiveOpenCallback*>(this);
                else if (iid == IID_IArchiveRequestMemoryUseCallback)
                    *out = static_cast<IArchiveRequestMemoryUseCallback*>(this);
                else return E_NOINTERFACE; // Never supply a password or open another volume.
                AddRef(); return S_OK;
            }
            STDMETHODIMP_(ULONG) AddRef() throw() override { return 2; }
            STDMETHODIMP_(ULONG) Release() throw() override { return 1; }
            STDMETHODIMP SetTotal(const UInt64* files, const UInt64*) throw() override
            {
                if (files && *files > MaximumItems) Limit.Limited = true;
                return Limit.Check() ? S_OK : E_ABORT;
            }
            STDMETHODIMP SetCompleted(const UInt64*, const UInt64*) throw() override
            { return Limit.Check() ? S_OK : E_ABORT; }
            STDMETHODIMP RequestMemoryUse(UInt32, UInt32, UInt32, const wchar_t*, UInt64 required,
                UInt64* allowed, UInt32* flags) throw() override
            {
                *allowed = MaximumMemory;
                if (required > MaximumMemory) { Limit.Limited = true; *flags |= 2; }
                return Limit.Check() ? S_OK : E_ABORT;
            }
        };

        struct CloseFile { void operator()(void* file) const { CloseHandle(file); } };
        struct CloseModule { void operator()(HINSTANCE__* module) const { FreeLibrary(module); } };
        struct CloseArchive { void operator()(IInArchive* archive) const { archive->Close(); archive->Release(); } };

        bool Insert(Node& root, std::wstring path, bool directory, unsigned& nodes)
        {
            if (path.empty() || path.size() > 4096 || path.find(L'\0') != std::wstring::npos) return false;
            std::replace(path.begin(), path.end(), L'\\', L'/');
            if (path.front() == L'/' || path.find(L':') != std::wstring::npos) return false;
            if (path.back() == L'/') { path.pop_back(); directory = true; }
            Node* parent = &root;
            size_t start = 0;
            unsigned depth = 0;
            while (start < path.size())
            {
                size_t end = path.find(L'/', start);
                bool last = end == std::wstring::npos;
                auto name = path.substr(start, last ? std::wstring::npos : end - start);
                if (name.empty() || name == L"." || name == L".." || ++depth > 64) return false;
                auto found = parent->Index.find(name);
                if (found == parent->Index.end())
                {
                    if (++nodes > MaximumNodes) return false;
                    size_t index = parent->Children.size();
                    parent->Index.emplace(name, index);
                    Node child; child.Name = name; child.Directory = !last || directory;
                    parent->Children.push_back(std::move(child));
                    found = parent->Index.find(name);
                }
                Node& child = parent->Children[found->second];
                if (child.Directory != (!last || directory)) return false;
                if (last) return true;
                parent = &child;
                start = end + 1;
            }
            return false;
        }

        std::wstring SafeName(std::wstring name)
        {
            for (wchar_t& c : name)
                if (c < L' ' || c == 0x7f || (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)) c = L' ';
            if (name.size() > 60)
            {
                size_t length = 57;
                if (name[length - 1] >= 0xd800 && name[length - 1] <= 0xdbff) --length;
                name.resize(length); name += L"...";
            }
            return name;
        }
    }

    bool Supports(const std::wstring& path)
    {
        auto dot = path.find_last_of(L'.');
        if (dot == std::wstring::npos) return false;
        auto extension = path.substr(dot);
        for (auto& c : extension) if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
        return extension == L".zip" || extension == L".7z" || extension == L".rar";
    }

    Result Read(const std::wstring& archivePath, const std::wstring& corePath, std::uint64_t milliseconds)
    {
        Result result;
        if (!Supports(archivePath)) { result.State = Status::Unsupported; return result; }
        if (!milliseconds) { result.State = Status::Limited; return result; }
        Budget budget{ GetTickCount64() + std::min<std::uint64_t>(milliseconds, 1000) };
        try
        {
            std::wstring path = archivePath;
            if (path.compare(0, 4, L"\\\\?\\") == 0) path.erase(0, 4);
            // No network/device paths, removable drives, reparse points or cloud hydration.
            if (path.size() < 3 || path[1] != L':' || path[2] != L'\\' || GetDriveTypeW(path.substr(0, 3).c_str()) != DRIVE_FIXED)
                return result;
            DWORD attributes = GetFileAttributesW(archivePath.c_str());
            if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY))
            { result.State = Status::Unsupported; return result; }
            if (attributes == INVALID_FILE_ATTRIBUTES || attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT |
                FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS | FILE_ATTRIBUTE_RECALL_ON_OPEN)) return result;
            std::unique_ptr<void, CloseFile> file(CreateFileW(archivePath.c_str(), GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
            if (file.get() == INVALID_HANDLE_VALUE) { file.release(); return result; }
            std::unique_ptr<HINSTANCE__, CloseModule> module(LoadLibraryExW(corePath.c_str(), nullptr,
                LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS));
            if (!module) return result;
            auto create = reinterpret_cast<HRESULT (WINAPI*)(const GUID*, const GUID*, void**)>(GetProcAddress(module.get(), "CreateObject"));
            if (!create) return result;
            Input input(file.get(), budget);
            Callback callback(budget);
            auto extension = path.substr(path.find_last_of(L'.'));
            for (auto& c : extension) if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
            const unsigned ids[] = { extension == L".zip" ? 1u : extension == L".7z" ? 7u : 0xccu, 3u };
            for (unsigned attempt = 0; attempt < (extension == L".rar" ? 2u : 1u); ++attempt)
            {
                if (!budget.Check()) break;
                input.Seek(0, FILE_BEGIN, nullptr);
                GUID classId = {0x23170f69,0x40c1,0x278a,{0x10,0,0,1,0x10,static_cast<BYTE>(ids[attempt]),0,0}};
                IInArchive* raw = nullptr;
                if (create(&classId, &IID_IInArchive, reinterpret_cast<void**>(&raw)) != S_OK || !raw) continue;
                std::unique_ptr<IInArchive, CloseArchive> archive(raw);
                const UInt64 scan = 1 << 16;
                if (archive->Open(&input, &scan, &callback) != S_OK) continue;
                // Some handlers recover partial entries and return S_OK even
                // when the archive is truncated. Do not present them as complete.
                PROPVARIANT errors = {};
                HRESULT errorResult = archive->GetArchiveProperty(kpidErrorFlags, &errors);
                bool invalid = FAILED(errorResult) ||
                    (errors.vt != VT_EMPTY && (errors.vt != VT_UI4 || errors.ulVal != 0));
                PropVariantClear(&errors);
                if (invalid) return result;
                UInt32 count = 0;
                if (archive->GetNumberOfItems(&count) != S_OK) return result;
                if (count > MaximumItems) { result.State = Status::Limited; return result; }
                unsigned nodes = 0;
                for (UInt32 i = 0; i < count; ++i)
                {
                    if (!budget.Check()) { result.State = Status::Limited; result.Root = Node(); return result; }
                    PROPVARIANT name = {}, directory = {};
                    HRESULT a = archive->GetProperty(i, kpidPath, &name);
                    HRESULT b = archive->GetProperty(i, kpidIsDir, &directory);
                    bool valid = a == S_OK && b == S_OK && name.vt == VT_BSTR && name.bstrVal &&
                        (directory.vt == VT_BOOL || directory.vt == VT_EMPTY);
                    if (valid) valid = Insert(result.Root, std::wstring(name.bstrVal, SysStringLen(name.bstrVal)),
                        directory.vt == VT_BOOL && directory.boolVal != VARIANT_FALSE, nodes);
                    PropVariantClear(&name); PropVariantClear(&directory);
                    if (!valid) { result.Root = Node(); return result; }
                }
                result.State = Status::Ready;
                return result;
            }
            if (budget.Limited) result.State = Status::Limited;
        }
        catch (...) { result.State = Status::Unavailable; result.Root = Node(); }
        return result;
    }

    Rows Flatten(const Result& result, size_t maximumRows, unsigned maximumDepth)
    {
        Rows rows;
        const auto visit = [&](const auto& self, const Node& parent, unsigned depth) -> void
        {
            for (const auto& node : parent.Children)
            {
                if (rows.Items.size() >= maximumRows || depth >= maximumDepth) { rows.Truncated = true; return; }
                rows.Items.push_back({SafeName(node.Name), depth, node.Directory});
                self(self, node, depth + 1);
            }
        };
        if (result.State == Status::Ready) visit(visit, result.Root, 0);
        return rows;
    }
}
