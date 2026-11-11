#include "recycle.h"

#include <windows.h>

#include <shlobj.h>
#include <shobjidl.h>

#include <string>
#include <thread>

namespace {

// Listens to the one deletion: Windows says for each item whether it will be recycled. One it
// would destroy instead is refused, which stops the operation before anything is removed.
class RecycleSink : public IFileOperationProgressSink {
 public:
  bool refused() const { return refused_; }

  // IUnknown
  IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (IsEqualIID(riid, __uuidof(IUnknown)) ||
        IsEqualIID(riid, __uuidof(IFileOperationProgressSink))) {
      *object = static_cast<IFileOperationProgressSink*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&references_));
  }
  IFACEMETHODIMP_(ULONG) Release() override {
    const LONG left = ::InterlockedDecrement(&references_);
    if (left == 0) {
      delete this;
    }
    return static_cast<ULONG>(left);
  }

  // IFileOperationProgressSink
  IFACEMETHODIMP StartOperations() override { return S_OK; }
  IFACEMETHODIMP FinishOperations(HRESULT) override { return S_OK; }
  IFACEMETHODIMP PreRenameItem(DWORD, IShellItem*, LPCWSTR) override {
    return S_OK;
  }
  IFACEMETHODIMP PostRenameItem(DWORD, IShellItem*, LPCWSTR, HRESULT,
                                IShellItem*) override {
    return S_OK;
  }
  IFACEMETHODIMP PreMoveItem(DWORD, IShellItem*, IShellItem*,
                             LPCWSTR) override {
    return S_OK;
  }
  IFACEMETHODIMP PostMoveItem(DWORD, IShellItem*, IShellItem*, LPCWSTR,
                              HRESULT, IShellItem*) override {
    return S_OK;
  }
  IFACEMETHODIMP PreCopyItem(DWORD, IShellItem*, IShellItem*,
                             LPCWSTR) override {
    return S_OK;
  }
  IFACEMETHODIMP PostCopyItem(DWORD, IShellItem*, IShellItem*, LPCWSTR,
                              HRESULT, IShellItem*) override {
    return S_OK;
  }
  IFACEMETHODIMP PreDeleteItem(DWORD flags, IShellItem*) override {
    if ((flags & TSF_DELETE_RECYCLE_IF_POSSIBLE) == 0) {
      // Windows is about to delete it for good: not here.
      refused_ = true;
      return E_ABORT;
    }
    return S_OK;
  }
  IFACEMETHODIMP PostDeleteItem(DWORD, IShellItem*, HRESULT,
                                IShellItem*) override {
    return S_OK;
  }
  IFACEMETHODIMP PreNewItem(DWORD, IShellItem*, LPCWSTR) override {
    return S_OK;
  }
  IFACEMETHODIMP PostNewItem(DWORD, IShellItem*, LPCWSTR, LPCWSTR, DWORD,
                             HRESULT, IShellItem*) override {
    return S_OK;
  }
  IFACEMETHODIMP UpdateProgress(UINT, UINT) override { return S_OK; }
  IFACEMETHODIMP ResetTimer() override { return S_OK; }
  IFACEMETHODIMP PauseTimer() override { return S_OK; }
  IFACEMETHODIMP ResumeTimer() override { return S_OK; }

 private:
  virtual ~RecycleSink() = default;

  LONG references_ = 1;
  bool refused_ = false;
};

bool Exists(const std::wstring& path) {
  return ::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

int Recycle(const std::wstring& path) {
  if (!Exists(path)) {
    return kRecycleFailed;
  }
  if (FAILED(::CoInitializeEx(
          nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE))) {
    return kRecycleFailed;
  }
  int code = kRecycleFailed;
  IFileOperation* operation = nullptr;
  if (SUCCEEDED(::CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL,
                                   IID_PPV_ARGS(&operation)))) {
    RecycleSink* sink = new RecycleSink();
    IShellItem* item = nullptr;
    // Into the Recycle Bin, with no window, no question and no error box of Windows' own.
    HRESULT result = operation->SetOperationFlags(
        FOF_ALLOWUNDO | FOF_NO_UI | FOFX_RECYCLEONDELETE | FOFX_EARLYFAILURE);
    if (SUCCEEDED(result)) {
      result = ::SHCreateItemFromParsingName(path.c_str(), nullptr,
                                             IID_PPV_ARGS(&item));
    }
    if (SUCCEEDED(result)) {
      result = operation->DeleteItem(item, sink);
    }
    if (SUCCEEDED(result)) {
      result = operation->PerformOperations();
    }
    BOOL aborted = FALSE;
    if (SUCCEEDED(result)) {
      operation->GetAnyOperationsAborted(&aborted);
    }
    if (sink->refused()) {
      code = kRecycleNoBin;
    } else if (SUCCEEDED(result) && !aborted && !Exists(path)) {
      code = kRecycleDone;
    }
    if (item != nullptr) {
      item->Release();
    }
    sink->Release();
    operation->Release();
  }
  ::CoUninitialize();
  return code;
}

}  // namespace

int RecycleStart(const wchar_t* path, RecycleFinished finished,
                 void* context) {
  if (path == nullptr || finished == nullptr) {
    return 0;
  }
  try {
    std::thread([target = std::wstring(path), finished, context] {
      finished(context, Recycle(target));
    }).detach();
  } catch (...) {
    return 0;
  }
  return 1;
}
