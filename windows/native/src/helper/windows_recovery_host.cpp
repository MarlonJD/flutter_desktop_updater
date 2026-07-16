#include "windows_recovery_host.h"

#include <taskschd.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <memory>
#include <regex>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

bool IsReadyNonce(const std::string& nonce) {
  return nonce.size() == 43 &&
         std::all_of(nonce.begin(), nonce.end(), [](unsigned char value) {
           return (value >= 'A' && value <= 'Z') ||
                  (value >= 'a' && value <= 'z') ||
                  (value >= '0' && value <= '9') || value == '-' ||
                  value == '_';
         });
}

template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  explicit ComPtr(T* value) : value_(value) {}
  ~ComPtr() {
    if (value_ != nullptr) value_->Release();
  }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;
  ComPtr(ComPtr&& other) noexcept : value_(other.release()) {}
  T* get() const { return value_; }
  T** put() {
    if (value_ != nullptr) {
      value_->Release();
      value_ = nullptr;
    }
    return &value_;
  }
  T* release() {
    T* result = value_;
    value_ = nullptr;
    return result;
  }

 private:
  T* value_ = nullptr;
};

class ScopedBstr {
 public:
  explicit ScopedBstr(const std::wstring& value)
      : value_(SysAllocStringLen(value.data(),
                                 static_cast<UINT>(value.size()))) {
    if (value_ == nullptr) {
      throw WindowsRecoveryHostError("Task Scheduler BSTR allocation failed");
    }
  }
  ~ScopedBstr() { SysFreeString(value_); }
  BSTR get() const { return value_; }

 private:
  BSTR value_;
};

class ReceivedBstr {
 public:
  ReceivedBstr() = default;
  ~ReceivedBstr() { SysFreeString(value_); }
  ReceivedBstr(const ReceivedBstr&) = delete;
  ReceivedBstr& operator=(const ReceivedBstr&) = delete;
  BSTR* put() { return &value_; }
  BSTR get() const { return value_; }

 private:
  BSTR value_ = nullptr;
};

class ScopedVariant {
 public:
  ScopedVariant() { VariantInit(&value_); }
  explicit ScopedVariant(const std::wstring& value) : ScopedVariant() {
    value_.vt = VT_BSTR;
    value_.bstrVal = SysAllocStringLen(
        value.data(), static_cast<UINT>(value.size()));
    if (value_.bstrVal == nullptr) {
      throw WindowsRecoveryHostError(
          "Task Scheduler VARIANT allocation failed");
    }
  }
  ~ScopedVariant() { VariantClear(&value_); }
  VARIANT value() const { return value_; }

 private:
  VARIANT value_;
};

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE value = nullptr) : value_(value) {}
  ~ScopedHandle() {
    if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) {
      CloseHandle(value_);
    }
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  HANDLE get() const { return value_; }
  bool valid() const {
    return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
  }

 private:
  HANDLE value_;
};

class ScopedComInitialization {
 public:
  ScopedComInitialization() {
    const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (result == S_OK || result == S_FALSE) {
      uninitialize_ = true;
    } else if (result != RPC_E_CHANGED_MODE) {
      throw WindowsRecoveryHostError(
          "Task Scheduler COM initialization failed");
    }
  }
  ~ScopedComInitialization() {
    if (uninitialize_) CoUninitialize();
  }

 private:
  bool uninitialize_ = false;
};

[[noreturn]] void Fail(const char* detail) {
  throw WindowsRecoveryHostError(detail);
}

void Check(HRESULT result, const char* detail) {
  if (FAILED(result)) Fail(detail);
}

void ValidateDefinition(const WindowsRecoveryHostTaskDefinition& definition) {
  const std::wstring wide_ready_nonce(definition.recovery_ready_nonce.begin(),
                                      definition.recovery_ready_nonce.end());
  if (!std::regex_match(definition.transaction_id, kTransactionId) ||
      !IsReadyNonce(definition.recovery_ready_nonce) ||
      definition.task_path.rfind(L"\\DesktopUpdater-", 0) != 0 ||
      definition.task_path.find(L'*') != std::wstring::npos ||
      definition.ready_event_name.rfind(
          L"Global\\DesktopUpdater-RecoveryReady-", 0) != 0 ||
      definition.ready_event_name.find(L'*') != std::wstring::npos ||
      definition.ready_event_name.size() <= wide_ready_nonce.size() + 1 ||
      definition.ready_event_name.compare(
          definition.ready_event_name.size() - wide_ready_nonce.size(),
          wide_ready_nonce.size(), wide_ready_nonce) != 0 ||
      !definition.executable_path.is_absolute() ||
      definition.executable_path.filename() !=
          L"desktop_updater_install_helper.exe" ||
      definition.arguments !=
          L"--recover-current " +
              std::wstring(definition.transaction_id.begin(),
                           definition.transaction_id.end()) ||
      definition.security_descriptor !=
          L"O:SYG:SYD:P(A;;GA;;;SY)(A;;GA;;;BA)" ||
      definition.principal_user_id != L"SYSTEM" ||
      definition.logon_type != TASK_LOGON_SERVICE_ACCOUNT ||
      definition.run_level != TASK_RUNLEVEL_HIGHEST ||
      definition.trigger_type != TASK_TRIGGER_BOOT ||
      definition.registration_flags !=
          (TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE) ||
      definition.run_flags != 0) {
    Fail("Windows recovery task definition is invalid");
  }
}

ComPtr<ITaskService> ConnectTaskService() {
  ComPtr<ITaskService> service;
  Check(CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
                         IID_ITaskService,
                         reinterpret_cast<void**>(service.put())),
        "Task Scheduler service creation failed");
  ScopedVariant empty;
  Check(service.get()->Connect(empty.value(), empty.value(), empty.value(),
                               empty.value()),
        "Task Scheduler service connection failed");
  return service;
}

ComPtr<ITaskFolder> RootTaskFolder(ITaskService* service) {
  ScopedBstr root(L"\\");
  ComPtr<ITaskFolder> folder;
  Check(service->GetFolder(root.get(), folder.put()),
        "Task Scheduler root folder is unavailable");
  return folder;
}

void ConfigureTaskDefinition(
    ITaskDefinition* task,
    const WindowsRecoveryHostTaskDefinition& definition) {
  ComPtr<IRegistrationInfo> registration;
  Check(task->get_RegistrationInfo(registration.put()),
        "Task Scheduler registration metadata is unavailable");
  ScopedBstr author(L"DesktopUpdater protected recovery host");
  Check(registration.get()->put_Author(author.get()),
        "Task Scheduler author binding failed");

  ComPtr<IPrincipal> principal;
  Check(task->get_Principal(principal.put()),
        "Task Scheduler principal is unavailable");
  ScopedBstr system(definition.principal_user_id);
  Check(principal.get()->put_UserId(system.get()),
        "Task Scheduler SYSTEM principal failed");
  Check(principal.get()->put_LogonType(definition.logon_type),
        "Task Scheduler service-account logon failed");
  Check(principal.get()->put_RunLevel(definition.run_level),
        "Task Scheduler highest run level failed");

  ComPtr<ITaskSettings> settings;
  Check(task->get_Settings(settings.put()),
        "Task Scheduler settings are unavailable");
  Check(settings.get()->put_Enabled(VARIANT_TRUE),
        "Task Scheduler enable failed");
  Check(settings.get()->put_AllowDemandStart(VARIANT_TRUE),
        "Task Scheduler demand-start policy failed");
  Check(settings.get()->put_StartWhenAvailable(VARIANT_TRUE),
        "Task Scheduler start-when-available policy failed");
  Check(settings.get()->put_DisallowStartIfOnBatteries(VARIANT_FALSE),
        "Task Scheduler battery policy failed");
  Check(settings.get()->put_StopIfGoingOnBatteries(VARIANT_FALSE),
        "Task Scheduler battery stop policy failed");
  Check(settings.get()->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW),
        "Task Scheduler instance policy failed");
  ScopedBstr no_limit(L"PT0S");
  Check(settings.get()->put_ExecutionTimeLimit(no_limit.get()),
        "Task Scheduler execution limit failed");

  ComPtr<ITriggerCollection> triggers;
  Check(task->get_Triggers(triggers.put()),
        "Task Scheduler trigger collection is unavailable");
  ComPtr<ITrigger> trigger;
  Check(triggers.get()->Create(definition.trigger_type, trigger.put()),
        "Task Scheduler boot trigger creation failed");
  Check(trigger.get()->put_Enabled(VARIANT_TRUE),
        "Task Scheduler boot trigger enable failed");

  ComPtr<IActionCollection> actions;
  Check(task->get_Actions(actions.put()),
        "Task Scheduler action collection is unavailable");
  ComPtr<IAction> action;
  Check(actions.get()->Create(TASK_ACTION_EXEC, action.put()),
        "Task Scheduler exec action creation failed");
  ComPtr<IExecAction> executable;
  Check(action.get()->QueryInterface(IID_IExecAction,
                                     reinterpret_cast<void**>(executable.put())),
        "Task Scheduler exec action binding failed");
  ScopedBstr path(definition.executable_path.wstring());
  ScopedBstr arguments(definition.arguments);
  Check(executable.get()->put_Path(path.get()),
        "Task Scheduler executable path binding failed");
  Check(executable.get()->put_Arguments(arguments.get()),
        "Task Scheduler argument binding failed");
}

void ValidateRegisteredTaskSecurity(IRegisteredTask* task) {
  ReceivedBstr encoded;
  Check(task->GetSecurityDescriptor(
            OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
                DACL_SECURITY_INFORMATION,
            encoded.put()),
        "Task Scheduler security descriptor readback failed");
  if (encoded.get() == nullptr) {
    Fail("Task Scheduler security descriptor readback is empty");
  }
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          encoded.get(), SDDL_REVISION_1, &raw_descriptor, nullptr) ||
      raw_descriptor == nullptr) {
    Fail("Task Scheduler security descriptor readback is invalid");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  PSID owner = nullptr;
  PSID group = nullptr;
  PACL dacl = nullptr;
  BOOL defaulted = FALSE;
  BOOL present = FALSE;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!GetSecurityDescriptorOwner(raw_descriptor, &owner, &defaulted) ||
      !GetSecurityDescriptorGroup(raw_descriptor, &group, &defaulted) ||
      !GetSecurityDescriptorDacl(raw_descriptor, &present, &dacl,
                                 &defaulted) ||
      present == FALSE || dacl == nullptr ||
      !GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    Fail("Task Scheduler owner or protected DACL readback failed");
  }
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> administrators_sid{};
  DWORD system_size = static_cast<DWORD>(system_sid.size());
  DWORD administrators_size =
      static_cast<DWORD>(administrators_sid.size());
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                          &system_size) ||
      !CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                          administrators_sid.data(),
                          &administrators_size) ||
      owner == nullptr || group == nullptr ||
      !EqualSid(owner, system_sid.data()) ||
      !EqualSid(group, system_sid.data())) {
    Fail("Task Scheduler owner/group is not LocalSystem");
  }
  bool system_full = false;
  bool administrators_full = false;
  if (dacl->AceCount != 2) {
    Fail("Task Scheduler DACL authority count changed");
  }
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) {
      Fail("Task Scheduler DACL readback is unreadable");
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) {
      Fail("Task Scheduler DACL contains unsupported authority");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if ((ace->Mask & GENERIC_ALL) != GENERIC_ALL) {
      Fail("Task Scheduler trusted authority lacks generic all access");
    }
    if (EqualSid(sid, system_sid.data())) {
      system_full = true;
    } else if (EqualSid(sid, administrators_sid.data())) {
      administrators_full = true;
    } else {
      Fail("Task Scheduler DACL grants an untrusted authority");
    }
  }
  if (!system_full || !administrators_full) {
    Fail("Task Scheduler DACL is incomplete");
  }
}

}  // namespace

WindowsRecoveryHostTaskDefinition BuildWindowsRecoveryHostTaskDefinition(
    const ProtectedWindowsHelperEndpointV1& endpoint,
    const std::string& transaction_id,
    const std::string& recovery_ready_nonce) {
  (void)endpoint.EncodeCanonical();
  if (!std::regex_match(transaction_id, kTransactionId) ||
      !IsReadyNonce(recovery_ready_nonce)) {
    Fail("Windows recovery task authority is invalid");
  }
  const std::wstring endpoint_key =
      ProtectedWindowsEndpointRegistryPath(endpoint.package_id,
                                           endpoint.helper_path);
  const std::wstring endpoint_hash =
      endpoint_key.substr(endpoint_key.find_last_of(L'\\') + 1, 16);
  const std::wstring wide_transaction(transaction_id.begin(),
                                      transaction_id.end());
  const std::wstring wide_ready_nonce(recovery_ready_nonce.begin(),
                                      recovery_ready_nonce.end());
  WindowsRecoveryHostTaskDefinition definition{
      transaction_id,
      recovery_ready_nonce,
      L"\\DesktopUpdater-" + endpoint_hash + L"-" + wide_transaction,
      L"Global\\DesktopUpdater-RecoveryReady-" + endpoint_hash + L"-" +
          wide_transaction + L"-" + wide_ready_nonce,
      endpoint.helper_path,
      L"--recover-current " + wide_transaction,
      L"O:SYG:SYD:P(A;;GA;;;SY)(A;;GA;;;BA)",
      L"SYSTEM",
      TASK_LOGON_SERVICE_ACCOUNT,
      TASK_RUNLEVEL_HIGHEST,
      TASK_TRIGGER_BOOT,
      TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE,
      0,
  };
  ValidateDefinition(definition);
  return definition;
}

void SignalWindowsRecoveryHostReady(
    const WindowsRecoveryHostTaskDefinition& definition) {
  ValidateDefinition(definition);
  ScopedHandle event(OpenEventW(EVENT_MODIFY_STATE, FALSE,
                                definition.ready_event_name.c_str()));
  if (!event.valid()) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND) return;
    Fail("Windows recovery readiness event cannot be opened");
  }
  if (!SetEvent(event.get())) {
    Fail("Windows recovery readiness event cannot be signalled");
  }
}

void TaskSchedulerWindowsRecoveryHostController::ArmAndStart(
    const WindowsRecoveryHostTaskDefinition& definition,
    DWORD startup_timeout_milliseconds) {
  ValidateDefinition(definition);
  if (startup_timeout_milliseconds == 0) {
    Fail("Windows recovery host startup timeout is invalid");
  }
  PSECURITY_DESCRIPTOR raw_event_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;SY)(A;;GR;;;BA)", SDDL_REVISION_1,
          &raw_event_descriptor, nullptr) ||
      raw_event_descriptor == nullptr) {
    Fail("Windows recovery readiness DACL construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> event_descriptor(
      raw_event_descriptor, LocalFree);
  SECURITY_ATTRIBUTES event_attributes{};
  event_attributes.nLength = sizeof(event_attributes);
  event_attributes.lpSecurityDescriptor = raw_event_descriptor;
  ScopedHandle ready_event(CreateEventW(
      &event_attributes, TRUE, FALSE, definition.ready_event_name.c_str()));
  if (!ready_event.valid() || GetLastError() == ERROR_ALREADY_EXISTS) {
    Fail("Windows recovery readiness event is unavailable");
  }
  ScopedComInitialization com;
  ComPtr<ITaskService> service = ConnectTaskService();
  ComPtr<ITaskFolder> folder = RootTaskFolder(service.get());
  ComPtr<ITaskDefinition> task;
  Check(service.get()->NewTask(0, task.put()),
        "Task Scheduler task definition creation failed");
  ConfigureTaskDefinition(task.get(), definition);

  ScopedBstr task_path(definition.task_path);
  ScopedVariant system(L"SYSTEM");
  ScopedVariant password;
  ScopedVariant security(definition.security_descriptor);
  ComPtr<IRegisteredTask> registered;
  const HRESULT registration = folder.get()->RegisterTaskDefinition(
      task_path.get(), task.get(), definition.registration_flags,
      system.value(), password.value(), definition.logon_type,
      security.value(), registered.put());
  if (registration != S_OK) {
    Fail("Task Scheduler protected recovery registration was incomplete");
  }
  ValidateRegisteredTaskSecurity(registered.get());

  ScopedVariant parameters;
  ComPtr<IRunningTask> running;
  Check(registered.get()->RunEx(parameters.value(), definition.run_flags, 0,
                                nullptr, running.put()),
        "Task Scheduler protected recovery start failed");
  const ULONGLONG started = GetTickCount64();
  for (;;) {
    if (WaitForSingleObject(ready_event.get(), 25) == WAIT_OBJECT_0) {
      return;
    }
    TASK_STATE state = TASK_STATE_UNKNOWN;
    if (FAILED(running.get()->get_State(&state)) ||
        state == TASK_STATE_DISABLED || state == TASK_STATE_READY) {
      Fail("Task Scheduler recovery host exited before readiness");
    }
    if (GetTickCount64() - started >= startup_timeout_milliseconds) {
      Fail("Task Scheduler recovery host startup timed out");
    }
  }
}

void TaskSchedulerWindowsRecoveryHostController::Disarm(
    const WindowsRecoveryHostTaskDefinition& definition) {
  ValidateDefinition(definition);
  ScopedComInitialization com;
  ComPtr<ITaskService> service = ConnectTaskService();
  ComPtr<ITaskFolder> folder = RootTaskFolder(service.get());
  ScopedBstr task_path(definition.task_path);
  const HRESULT result = folder.get()->DeleteTask(task_path.get(), 0);
  constexpr HRESULT task_not_found =
      static_cast<HRESULT>(0x8004130FUL);
  if (FAILED(result) && result != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) &&
      result != task_not_found) {
    Fail("Task Scheduler recovery host removal failed");
  }
}

}  // namespace desktop_updater::helper
