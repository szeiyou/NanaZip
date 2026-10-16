// Direct archive API checks for cancellation, output errors and callback order.
// Build in a VS x64 developer environment:
// cl /EHsc /std:c++17 Tests\ZipCallbackTests.cpp /Fe:ZipCallbackTests.exe /link ole32.lib
#define NOMINMAX
#include <windows.h>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include "../NanaZip.Core/SevenZip/CPP/Common/MyInitGuid.h"
#include "../NanaZip.Core/SevenZip/CPP/7zip/Archive/IArchive.h"

class Input final: public IInStream
{
  HANDLE _file;
public:
  bool FailReads = false;
  bool ShortReads = false;
  std::atomic<UInt64> Bytes{0};
  explicit Input(const wchar_t *path): _file(CreateFileW(path, GENERIC_READ,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr)) {}
  ~Input() { CloseHandle(_file); }
  STDMETHODIMP QueryInterface(REFIID id, void **out) throw() override
  {
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_ISequentialInStream && id != IID_IInStream)
      return E_NOINTERFACE;
    *out = static_cast<IInStream *>(this);
    AddRef();
    return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() throw() override { return 2; }
  STDMETHODIMP_(ULONG) Release() throw() override { return 1; }
  STDMETHODIMP Read(void *data, UInt32 size, UInt32 *processed) throw() override
  {
    *processed = 0;
    if (FailReads && Bytes.load() > (1 << 20))
      return E_FAIL;
    if (ShortReads)
      size = std::min(size, (UInt32)16384);
    DWORD read = 0;
    if (!ReadFile(_file, data, size, &read, nullptr))
      return HRESULT_FROM_WIN32(GetLastError());
    *processed = read;
    Bytes.fetch_add(read);
    return S_OK;
  }
  STDMETHODIMP Seek(Int64 offset, UInt32 origin, UInt64 *position) throw() override
  {
    LARGE_INTEGER distance, result;
    distance.QuadPart = offset;
    if (!SetFilePointerEx(_file, distance, &result, origin))
      return HRESULT_FROM_WIN32(GetLastError());
    if (position)
      *position = result.QuadPart;
    return S_OK;
  }
};

class Output final: public ISequentialOutStream
{
public:
  bool Fail = false;
  bool Zero = false;
  bool Partial = false;
  std::atomic<UInt64> Bytes{0};
  STDMETHODIMP QueryInterface(REFIID id, void **out) throw() override
  {
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_ISequentialOutStream)
      return E_NOINTERFACE;
    *out = static_cast<ISequentialOutStream *>(this);
    AddRef();
    return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() throw() override { return 2; }
  STDMETHODIMP_(ULONG) Release() throw() override { return 1; }
  STDMETHODIMP Write(const void *, UInt32 size, UInt32 *processed) throw() override
  {
    *processed = 0;
    if (Fail)
      return E_FAIL;
    if (!Zero)
      *processed = Partial ? std::min(size, (UInt32)4093) : size;
    Bytes.fetch_add(*processed);
    return S_OK;
  }
};

class Callback final: public IArchiveExtractCallback
{
  DWORD _thread = GetCurrentThreadId();
  unsigned _state = 0;
  UInt64 _completed = 0;
public:
  const char *Mode;
  Output Out;
  UInt64 Total = 0;
  unsigned Results = 0;
  unsigned OperationErrors = 0;
  explicit Callback(const char *mode): Mode(mode)
  {
    Out.Fail = !strcmp(mode, "write-fail");
    Out.Zero = !strcmp(mode, "write-zero");
    Out.Partial = !strcmp(mode, "partial");
  }
  STDMETHODIMP QueryInterface(REFIID id, void **out) throw() override
  {
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_IProgress && id != IID_IArchiveExtractCallback)
      return E_NOINTERFACE;
    *out = static_cast<IArchiveExtractCallback *>(this);
    AddRef();
    return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() throw() override { return 2; }
  STDMETHODIMP_(ULONG) Release() throw() override { return 1; }
  STDMETHODIMP SetTotal(UInt64 total) throw() override { Total = total; return S_OK; }
  STDMETHODIMP SetCompleted(const UInt64 *completed) throw() override
  {
    if (GetCurrentThreadId() != _thread || (completed && *completed < _completed))
      return E_UNEXPECTED;
    if (completed)
      _completed = *completed;
    if (!strcmp(Mode, "cancel"))
    {
      // Let decode-ahead workers fill the bounded pool before cancellation.
      Sleep(200);
      return E_ABORT;
    }
    return S_OK;
  }
  STDMETHODIMP GetStream(UInt32, ISequentialOutStream **out, Int32) throw() override
  {
    *out = nullptr;
    if (_state != 0 || GetCurrentThreadId() != _thread)
      return E_UNEXPECTED;
    if (!strcmp(Mode, "getstream-fail"))
      return E_ABORT;
    _state = 1;
    *out = &Out;
    Out.AddRef();
    return S_OK;
  }
  STDMETHODIMP PrepareOperation(Int32) throw() override
  {
    if (_state != 1 || GetCurrentThreadId() != _thread)
      return E_UNEXPECTED;
    if (!strcmp(Mode, "prepare-fail"))
      return E_ABORT;
    _state = 2;
    return S_OK;
  }
  STDMETHODIMP SetOperationResult(Int32 result) throw() override
  {
    if (_state != 2 || GetCurrentThreadId() != _thread)
      return E_UNEXPECTED;
    if (result != 0)
      OperationErrors++;
    _state = 0;
    Results++;
    return !strcmp(Mode, "result-fail") ? E_ABORT : S_OK;
  }
};

int wmain(int argc, wchar_t **argv)
{
  if (argc != 3)
    return 2;
  HMODULE module = LoadLibraryExW(argv[1], nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!module)
    return 3;
  using CreateObjectFunc = HRESULT (WINAPI *)(const GUID *, const GUID *, void **);
  auto create = reinterpret_cast<CreateObjectFunc>(GetProcAddress(module, "CreateObject"));
  const GUID zipId = {0x23170F69, 0x40C1, 0x278A, {0x10, 0, 0, 1, 0x10, 1, 0, 0}};
  const char *modes[] = {"normal", "partial", "short-read", "cancel", "write-fail",
      "write-zero", "getstream-fail", "prepare-fail", "result-fail", "read-fail"};
  for (const char *mode: modes)
  {
    Input input(argv[2]);
    IInArchive *archive = nullptr;
    if (!create || create(&zipId, &IID_IInArchive, reinterpret_cast<void **>(&archive)) != S_OK)
      return 4;
    if (archive->Open(&input, nullptr, nullptr) != S_OK)
      return 5;
    ISetProperties *properties = nullptr;
    if (archive->QueryInterface(IID_ISetProperties, reinterpret_cast<void **>(&properties)) != S_OK)
      return 7;
    const wchar_t *names[] = {L"mt", L"memuse"};
    PROPVARIANT values[2] = {};
    values[0].vt = VT_UI4;
    values[0].ulVal = 2;
    values[1].vt = VT_UI8;
    values[1].uhVal.QuadPart = 16 << 20;
    if (properties->SetProperties(names, values, 2) != S_OK)
      return 8;
    properties->Release();
    Callback callback(mode);
    input.ShortReads = !strcmp(mode, "short-read");
    input.FailReads = !strcmp(mode, "read-fail");
    const HRESULT result = archive->Extract(nullptr, (UInt32)-1, 0, &callback);
    const bool success = !strcmp(mode, "normal") || !strcmp(mode, "partial") || !strcmp(mode, "short-read");
    const HRESULT expected = success ? S_OK :
        (!strcmp(mode, "write-fail") || !strcmp(mode, "write-zero") || !strcmp(mode, "read-fail") ? E_FAIL : E_ABORT);
    const bool zeroWriteFailure = !strcmp(mode, "write-zero")
        && (result == E_FAIL || (result == S_OK && callback.OperationErrors != 0));
    if ((!zeroWriteFailure && result != expected)
        || (success && (callback.Out.Bytes.load() != callback.Total || callback.OperationErrors != 0)))
    {
      printf("FAIL: %s HRESULT=%08lx, expected=%08lx\n", mode, result, expected);
      return 6;
    }
    printf("PASS: %s\n", mode);
    if (success)
    {
      Callback repeated("normal");
      if (archive->Extract(nullptr, (UInt32)-1, 0, &repeated) != S_OK
          || repeated.Out.Bytes.load() != repeated.Total || repeated.OperationErrors != 0)
        return 9;
      printf("PASS: repeated Extract on the same archive\n");
    }
    archive->Close();
    archive->Release();
  }
  FreeLibrary(module);
  return 0;
}
