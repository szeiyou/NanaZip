// Included by ZipHandler.cpp inside NArchive::NZip, after CZipDecoder.
// Decode ahead into a bounded buffer pool. Only the calling thread invokes
// extraction callbacks, preserving overwrite, metadata and error ordering.

struct CZipMtInput
{
  CMyComPtr<IInStream> Stream;
  NSynchronization::CCriticalSection Lock;
  std::atomic<bool> Stop;
  UInt64 OriginalPos;
  bool RestorePos;

  CZipMtInput(): Stop(false), OriginalPos(0), RestorePos(false) {}
};

Z7_CLASS_IMP_NOQIB_1(CZipMtInStream, ISequentialInStream)
  CZipMtInput *_input;
  UInt64 _pos;
public:
  void Init(CZipMtInput *input, UInt64 pos) { _input = input; _pos = pos; }
};

Z7_COM7F_IMF(CZipMtInStream::Read(void *data, UInt32 size, UInt32 *processedSize))
{
  if (processedSize)
    *processedSize = 0;
  if (_input->Stop.load())
    return E_ABORT;
  NSynchronization::CCriticalSectionLock lock(_input->Lock);
  RINOK(InStream_SeekSet(_input->Stream, _pos))
  UInt32 processed = 0;
  const HRESULT result = _input->Stream->Read(data, size, &processed);
  _pos += processed;
  if (processedSize)
    *processedSize = processed;
  return result;
}

Z7_CLASS_IMP_NOQIB_1(CZipMtProgress, ICompressProgressInfo)
public:
  CZipMtInput *Input;
  std::atomic<UInt64> InSize;
  std::atomic<UInt64> OutSize;

  void Init(CZipMtInput *input)
  {
    Input = input;
    InSize.store(0);
    OutSize.store(0);
  }
};

Z7_COM7F_IMF(CZipMtProgress::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize))
{
  if (inSize)
    InSize.store(*inSize);
  if (outSize)
    OutSize.store(*outSize);
  return Input->Stop.load() ? E_ABORT : S_OK;
}

struct CZipMtWorker
{
  NWindows::CThread Thread;
  NSynchronization::CAutoResetEvent Start;
  NSynchronization::CManualResetEvent Done;
  CZipMtInput *Input;
  CInArchive *Archive;
  const CItemEx *Item;
  UInt64 MemUsage;
  HRESULT Result;
  Int32 OperationResult;
  CZipDecoder Decoder;
  CMyComPtr2<ISequentialInStream, CZipMtInStream> InStream;
  CMyComPtr2<ISequentialOutStream, COutMemStream> OutStream;
  CMyComPtr2<ICompressProgressInfo, CZipMtProgress> Progress;
  DECL_EXTERNAL_CODECS_LOC_VARS_DECL

  static THREAD_FUNC_DECL Run(void *param)
  {
    CZipMtWorker &worker = *(CZipMtWorker *)param;
    for (;;)
    {
      if (worker.Start.Lock() != 0 || worker.Input->Stop.load())
        break;
      try
      {
        worker.Result = worker.Decoder.Decode(
            #ifdef Z7_EXTERNAL_CODECS
            worker._externalCodecs,
            #endif
            *worker.Archive, *worker.Item, worker.OutStream,
            NULL, worker.Progress, 1, worker.MemUsage,
            worker.OperationResult, worker.InStream);
      }
      catch (...)
      {
        worker.Result = E_OUTOFMEMORY;
      }
      worker.Done.Set();
    }
    return 0;
  }

  HRESULT Init(CZipMtInput *input, CInArchive *archive,
      CMemBlockManagerMt *manager, UInt64 memUsage)
  {
    Input = input;
    Archive = archive;
    MemUsage = memUsage;
    RINOK(HRESULT_FROM_WIN32(Start.Create()))
    RINOK(HRESULT_FROM_WIN32(Done.Create()))
    InStream.SetFromCls(new CZipMtInStream);
    OutStream.SetFromCls(new COutMemStream(manager));
    Progress.SetFromCls(new CZipMtProgress);
    RINOK(OutStream->CreateEvents(SYNC_WFMO(&manager->Synchro)))
    return HRESULT_FROM_WIN32(Thread.Create(Run, this));
  }

  HRESULT Begin(const CItemEx &item)
  {
    // The previous job has been joined logically via Done, and fully drained.
    RINOK(HRESULT_FROM_WIN32(Done.Reset()))
    // Reset StopWritingEvent as well when reusing a slot.
    RINOK(OutStream->CreateEvents(SYNC_WFMO(NULL)))
    OutStream->Init();
    OutStream->ReleaseOutStream();
    Progress->Init(Input);
    Item = &item;
    InStream->Init(Input, (UInt64)(Archive->ArcInfo.Base + (Int64)item.GetDataPosition()));
    return HRESULT_FROM_WIN32(Start.Set());
  }
};

class CZipMtWorkers
{
public:
  CMemBlockManagerMt Manager;
  CZipMtInput Input;
  CObjectVector<CZipMtWorker> Workers;

  ~CZipMtWorkers()
  {
    Input.Stop.store(true);
    FOR_VECTOR (i, Workers)
    {
      CZipMtWorker &worker = Workers[i];
      if (worker.OutStream.IsDefined())
        worker.OutStream->StopWriting(E_ABORT);
      if (worker.Start.IsCreated())
        worker.Start.Set();
    }
    FOR_VECTOR (i, Workers)
      if (Workers[i].Thread.IsCreated())
        Workers[i].Thread.Wait_Close();
    // OutMemStream releases pool blocks before Manager is destroyed.
    Workers.Clear();
    // CInArchive retains a read cache with its own physical-position accounting.
    // Restore the shared stream after the workers' independent seeks.
    if (Input.RestorePos)
      InStream_SeekSet(Input.Stream, Input.OriginalPos);
  }
};

static HRESULT ExtractZipMt(
    DECL_EXTERNAL_CODECS_LOC_VARS
    CInArchive &archive, const CObjectVector<CItemEx> &archiveItems,
    const UInt32 *indices, UInt32 numItems, bool allFiles,
    Int32 testMode, IArchiveExtractCallback *callback,
    const CBaseProps &props, bool &used)
{
  used = false;
  if (props._numThreads < 2 || archive.IsMultiVol || !archive.ArcInfo.CdWasRead
      || archive.AreThereErrors() || archive.ArcInfo.Base < 0)
    return S_OK;

  UInt64 total = 0;
  unsigned numFiles = 0;
  // Keep tiny files and unusual ZIP features on the established serial path.
  for (UInt32 i = 0; i < numItems; i++)
  {
    const CItemEx &item = archiveItems[allFiles ? i : indices[i]];
    if (item.IsEncrypted() || !archive.IsLocalOffsetOK(item)
        || (archive.UseDisk_in_SingleVol && item.Disk != archive.EcdVolIndex)
        || (item.Method != NFileHeader::NCompressionMethod::kStore
            && item.Method != NFileHeader::NCompressionMethod::kDeflate))
      return S_OK;
    UInt32 attrib;
    if (item.GetPosixAttrib(attrib) && (attrib & 0170000) == 0120000)
      return S_OK;
    if (!item.IsDir())
    {
      total += item.Size;
      numFiles++;
    }
  }
  if (numFiles < 2 || total < ((UInt64)32 << 20)
      || total / numFiles < ((UInt64)1 << 20))
    return S_OK;

  unsigned numThreads = MyMin((unsigned)props._numThreads, 8u);
  numThreads = MyMin(numThreads, numFiles);
  // At most 512 MiB of output buffering, and never more than the user limit.
  const UInt64 blockSize = (UInt64)1 << 20;
  const UInt64 budget = MyMin(total, MyMin(props._memUsage_Decompress / 2,
      (UInt64)numThreads << 26));
  if (budget < ((UInt64)numThreads << 22))
    return S_OK;

  CObjectVector<CItemEx> items;
  CUIntVector fileIndices;
  for (UInt32 i = 0; i < numItems; i++)
  {
    CItemEx &item = items.AddNew();
    item = archiveItems[allFiles ? i : indices[i]];
    if (!item.FromLocal)
    {
      bool available = true;
      bool headersError = false;
      const HRESULT result = archive.Read_LocalItem_After_CdItem(item, available, headersError);
      // Before dispatching any jobs or callbacks, fall back on malformed headers.
      if (result != S_OK || !available || headersError)
        return S_OK;
    }
    // Recheck properties after reading the local header.
    if (item.IsEncrypted() || item.IsBadDescriptor()
        || (item.Method != NFileHeader::NCompressionMethod::kStore
            && item.Method != NFileHeader::NCompressionMethod::kDeflate))
      return S_OK;
    if (!item.IsDir())
      fileIndices.Add(i);
  }
  if (fileIndices.Size() < 2)
    return S_OK;
  numThreads = MyMin(numThreads, fileIndices.Size());

  CZipMtWorkers pool;
  pool.Input.Stream = archive.GetBaseStream();
  if (InStream_GetPos(pool.Input.Stream, pool.Input.OriginalPos) != S_OK)
    return S_OK;
  pool.Input.RestorePos = true;
  const HRESULT allocResult = pool.Manager.AllocateSpaceAlways((size_t)(budget / blockSize));
  if (allocResult != S_OK)
    return S_OK;
  for (unsigned i = 0; i < numThreads; i++)
  {
    CZipMtWorker &worker = pool.Workers.AddNew();
    #ifdef Z7_EXTERNAL_CODECS
    worker._externalCodecs = _externalCodecs;
    #endif
    const HRESULT result = worker.Init(&pool.Input, &archive, &pool.Manager,
        props._memUsage_Decompress / numThreads);
    if (result != S_OK)
      return S_OK;
  }
  used = true;
  for (unsigned i = 0; i < numThreads; i++)
    RINOK(pool.Workers[i].Begin(items[fileIndices[i]]))

  CMyComPtr2_Create<ICompressProgressInfo, CLocalProgress> progress;
  progress->Init(callback, false);
  CMyComPtr2_Create<ISequentialOutStream, COutStreamWithCRC> discard;
  discard->SetStream(NULL);
  discard->Init(false);
  unsigned fileNumber = 0;
  for (UInt32 i = 0; i < numItems; i++)
  {
    RINOK(progress->SetCur())
    const CItemEx &item = items[i];
    const Int32 askMode = testMode ? NExtract::NAskMode::kTest : NExtract::NAskMode::kExtract;
    CMyComPtr<ISequentialOutStream> outStream;
    RINOK(callback->GetStream(allFiles ? i : indices[i], &outStream, askMode))
    const bool skip = !testMode && !outStream && !item.IsDir();
    if (!skip)
      RINOK(callback->PrepareOperation(askMode))
    if (item.IsDir())
    {
      outStream.Release();
      RINOK(callback->SetOperationResult(NExtract::NOperationResult::kOK))
    }
    else
    {
      CZipMtWorker &worker = pool.Workers[fileNumber % numThreads];
      worker.OutStream->SetSeqOutStream(outStream ? outStream.Interface() : discard.Interface());
      worker.OutStream->SetRealStreamMode();
      for (;;)
      {
        const DWORD waitResult = ::WaitForSingleObject(worker.Done, 50);
        if (waitResult == WAIT_OBJECT_0)
          break;
        if (waitResult != WAIT_TIMEOUT)
          return HRESULT_FROM_WIN32(::GetLastError());
        const UInt64 inSize = worker.Progress->InSize.load();
        const UInt64 outSize = worker.Progress->OutSize.load();
        RINOK(progress.Interface()->SetRatioInfo(&inSize, &outSize))
      }
      if (!skip)
        RINOK(worker.Result)
      // A job can finish entirely in memory before consuming the real-stream event.
      RINOK(worker.OutStream->WriteToRealStream())
      worker.OutStream->ReleaseOutStream();
      outStream.Release();
      if (!skip)
        RINOK(callback->SetOperationResult(worker.OperationResult))
      const unsigned nextFile = fileNumber + numThreads;
      if (nextFile < fileIndices.Size())
        RINOK(worker.Begin(items[fileIndices[nextFile]]))
      fileNumber++;
    }
    progress->InSize += item.PackSize;
    progress->OutSize += item.Size;
  }
  return progress->SetCur();
}
