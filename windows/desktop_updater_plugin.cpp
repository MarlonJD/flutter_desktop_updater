#include "desktop_updater_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <VersionHelpers.h>
#include <Shlwapi.h> // Include Shlwapi.h for PathFileExistsW

// Link required Windows libraries
#pragma comment(lib, "Version.lib")
#pragma comment(lib, "Shlwapi.lib")

// Flutter includes
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

// Standard library includes
#include <memory>
#include <sstream>
#include <filesystem>
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <string>
#include <vector>

namespace fs = std::filesystem;
namespace desktop_updater
{
  /**
   * @brief Register the plugin with the Flutter registrar
   * @param registrar The Flutter plugin registrar for Windows
   */
  void DesktopUpdaterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "desktop_updater",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<DesktopUpdaterPlugin>();

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  DesktopUpdaterPlugin::DesktopUpdaterPlugin() {}

  DesktopUpdaterPlugin::~DesktopUpdaterPlugin() {}

  /**
   * @brief Converts a wide string to UTF-8 string
   * @param wideStr The wide string to convert
   * @return UTF-8 encoded string
   */
  std::string WideStringToUtf8(const std::wstring &wideStr)
  {
    if (wideStr.empty()) return {};

    int size = WideCharToMultiByte(CP_UTF8, 0, wideStr.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return {};

    std::string result(size - 1, 0); // Exclude null terminator
    WideCharToMultiByte(CP_UTF8, 0, wideStr.c_str(), -1, &result[0], size - 1, nullptr, nullptr);

    return result;
  }

  /**
   * @brief Extracts the executable name from a full path
   * @param fullPath The full path to the executable
   * @return The executable name without path
   */
  std::string ExtractExecutableName(const std::string &fullPath)
  {
    size_t pos = fullPath.find_last_of("\\");
    return (pos != std::string::npos) ? fullPath.substr(pos + 1) : fullPath;
  }

  /**
   * @brief Creates a robust batch script for handling application updates
   *
   * This function generates a comprehensive batch script that:
   * 1. Waits for the application to close properly
   * 2. Creates a complete backup of the current application
   * 3. Copies new update files with retry logic
   * 4. Restores backup if update fails
   * 5. Cleans up temporary files and restarts the application
   *
   * @param updateDir Directory containing the update files
   * @param destDir Destination directory (usually current directory)
   * @param executable_path Full path to the application executable
   */
  void createBatFile(const std::wstring &updateDir, const std::wstring &destDir, const wchar_t *executable_path)
  {
    // Convert wide strings to UTF-8 for batch script generation
    std::string updateDirStr = WideStringToUtf8(updateDir);
    std::string destDirStr = WideStringToUtf8(destDir);
    std::string exePathStr = WideStringToUtf8(executable_path);
    std::string exeNameStr = ExtractExecutableName(exePathStr);

    // Constants for the update process
    const int MAX_WAIT_ATTEMPTS = 5;
    const int MAX_RETRY_ATTEMPTS = 3;
    const int RETRY_DELAY_SECONDS = 2;

    const std::string batScript =
        "@echo off\n"
        "chcp 65001 > NUL\n"  // Enable UTF-8 support for non-ASCII paths
        "echo.\n"
        "echo ==========================================\n"
        "echo        Application Update Process\n"
        "echo ==========================================\n"
        "echo.\n"

        // STEP 1: Wait for application to close gracefully
        "echo [STEP 1/5] Waiting for application to close...\n"
        "set COUNT=0\n"
        ":wait_loop\n"
        "tasklist /FI \"IMAGENAME eq " + exeNameStr + "\" 2>NUL | find /I \"" + exeNameStr + "\" >NUL\n"
        "if \"%ERRORLEVEL%\"==\"0\" (\n"
        "    set /a COUNT+=1\n"
        "    echo   Attempt %COUNT%/" + std::to_string(MAX_WAIT_ATTEMPTS) + " - Application still running...\n"
        "    if %COUNT% GEQ " + std::to_string(MAX_WAIT_ATTEMPTS) + " (\n"
        "        echo   Timeout reached - force closing application\n"
        "        taskkill /F /IM \"" + exeNameStr + "\" >NUL 2>&1\n"
        "        goto step2\n"
        "    )\n"
        "    timeout /t 1 /nobreak > NUL\n"
        "    goto wait_loop\n"
        ")\n"
        "echo   Application closed successfully\n"
        "echo.\n"

        // STEP 2: Create complete backup
        ":step2\n"
        "echo [STEP 2/5] Creating backup restore point...\n"
        "if exist backup (\n"
        "    echo   Removing old backup...\n"
        "    rmdir /s /q backup >NUL 2>&1\n"
        ")\n"
        "mkdir backup >NUL 2>&1\n"
        "echo   Backing up application files...\n"

        // Backup files (excluding backup folder and update script)
        "for %%F in (*) do (\n"
        "    if not \"%%F\"==\"backup\" (\n"
        "        if not \"%%F\"==\"update_script.bat\" (\n"
        "            copy \"%%F\" \"backup\\%%F\" >NUL 2>&1\n"
        "        )\n"
        "    )\n"
        ")\n"

        // Backup directories (excluding backup and update folders)
        "for /D %%D in (*) do (\n"
        "    if not \"%%D\"==\"backup\" (\n"
        "        if not \"%%D\"==\"update\" (\n"
        "            xcopy /E /H /C /I /Y \"%%D\" \"backup\\%%D\\\" >NUL 2>&1\n"
        "        )\n"
        "    )\n"
        ")\n"
        "echo   Backup completed successfully\n"
        "echo.\n"

        // STEP 3: Apply update with retry logic
        "echo [STEP 3/5] Applying update...\n"
        "set RETRY=0\n"
        ":retry_copy\n"
        "set /a RETRY+=1\n"
        "echo   Update attempt %RETRY%/" + std::to_string(MAX_RETRY_ATTEMPTS) + "...\n"
        "xcopy /E /I /Y \"" + updateDirStr + "\\*\" \"" + destDirStr + "\\\" >NUL 2>&1\n"
        "if %ERRORLEVEL% EQU 0 (\n"
        "    echo   Update applied successfully\n"
        "    rmdir /s /q backup >NUL 2>&1\n"
        "    goto cleanup\n"
        ")\n"
        "if %RETRY% LSS " + std::to_string(MAX_RETRY_ATTEMPTS) + " (\n"
        "    echo   Update failed - retrying in " + std::to_string(RETRY_DELAY_SECONDS) + " seconds...\n"
        "    timeout /t " + std::to_string(RETRY_DELAY_SECONDS) + " /nobreak > NUL\n"
        "    goto retry_copy\n"
        ")\n"
        "echo   All update attempts failed\n"
        "echo.\n"

        // STEP 4: Restore backup if update failed
        "echo [STEP 4/5] Restoring from backup...\n"
        "echo   Update failed - restoring previous version\n"
        "xcopy /E /H /C /I /Y backup\\*.* . >NUL 2>&1\n"
        "if %ERRORLEVEL% EQU 0 (\n"
        "    echo   Backup restored successfully\n"
        ") else (\n"
        "    echo   WARNING: Some files may not have been restored properly\n"
        ")\n"
        "rmdir /s /q backup >NUL 2>&1\n"
        "echo.\n"

        // STEP 5: Cleanup and restart
        ":cleanup\n"
        "echo [STEP 5/5] Cleanup and restart...\n"
        "echo   Removing update files...\n"
        "rmdir /S /Q \"" + updateDirStr + "\" >NUL 2>&1\n"
        "echo   Starting application in foreground...\n"
        "start /MAX \"\" \"" + exePathStr + "\"\n"
        "timeout /t 1 /nobreak > NUL\n"
        "echo   Cleaning up temporary files...\n"
        "del update_script.bat >NUL 2>&1\n"
        "echo.\n"
        "echo Update process completed.\n"
        "exit\n";

    // Write the batch script to file
    std::ofstream batFile("update_script.bat");
    if (batFile.is_open()) {
      batFile << batScript;
      batFile.close();
      std::cout << "Update batch script created successfully.\n";
    } else {
      std::cerr << "Error: Failed to create update batch script.\n";
    }
  }

  /**
   * @brief Executes the update batch script in a separate process
   *
   * Creates a new process to run the update script with CREATE_NO_WINDOW flag
   * to hide the console window from the user.
   */
  void runBatFile()
  {
    STARTUPINFO si = {sizeof(si)};
    PROCESS_INFORMATION pi;

    WCHAR cmdLine[] = L"cmd.exe /c update_script.bat";

    BOOL success = CreateProcess(
        nullptr,                    // Application name
        cmdLine,                    // Command line
        nullptr,                    // Process security attributes
        nullptr,                    // Thread security attributes
        FALSE,                      // Inherit handles
        CREATE_NO_WINDOW,           // Hide console window
        nullptr,                    // Environment
        nullptr,                    // Current directory
        &si,                        // Startup info
        &pi                         // Process info
    );

    if (success) {
      // Close handles immediately as we don't need to wait for the process
      CloseHandle(pi.hProcess);
      CloseHandle(pi.hThread);
      std::cout << "Update script started successfully.\n";
    } else {
      DWORD error = GetLastError();
      std::cerr << "Error: Failed to start update script. Error code: " << error << "\n";
    }
  }

  void RestartApp()
  {
    printf("Restarting the application...\n");
    // Get the current executable file path
    char szFilePath[MAX_PATH];
    GetModuleFileNameA(NULL, szFilePath, MAX_PATH);

    // Get the current executable path
    wchar_t executable_path[MAX_PATH];
    GetModuleFileNameW(NULL, executable_path, MAX_PATH);

    printf("Executable path: %ls\n", executable_path);

    // Replace the existing copyDirectory lambda with copyAndReplaceFiles function
    std::wstring updateDir = L"update";
    std::wstring destDir = L".";

    // Update createBatFile call with parameters
    createBatFile(updateDir, destDir, executable_path);

    // 3. .bat dosyasını çalıştır
    runBatFile();

    // Exit the current process
    ExitProcess(0);
  }

  void DesktopUpdaterPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name().compare("getPlatformVersion") == 0)
    {
      std::ostringstream version_stream;
      version_stream << "Windows ";
      if (IsWindows10OrGreater())
      {
        version_stream << "10+";
      }
      else if (IsWindows8OrGreater())
      {
        version_stream << "8";
      }
      else if (IsWindows7OrGreater())
      {
        version_stream << "7";
      }
      result->Success(flutter::EncodableValue(version_stream.str()));
    }
    else if (method_call.method_name().compare("restartApp") == 0)
    {
      RestartApp();
      result->Success();
    }
    else if (method_call.method_name().compare("getExecutablePath") == 0)
    {
      wchar_t executable_path[MAX_PATH];
      GetModuleFileNameW(NULL, executable_path, MAX_PATH);

      // Convert wchar_t to std::string (UTF-8)
      int size_needed = WideCharToMultiByte(CP_UTF8, 0, executable_path, -1, NULL, 0, NULL, NULL);
      std::string executablePathStr(size_needed, 0);
      WideCharToMultiByte(CP_UTF8, 0, executable_path, -1, &executablePathStr[0], size_needed, NULL, NULL);

      result->Success(flutter::EncodableValue(executablePathStr));
    }
    else if (method_call.method_name().compare("getCurrentVersion") == 0)
    {
      // Get only bundle version, Product version 1.0.0+2, should return 2
      wchar_t exePath[MAX_PATH];
      GetModuleFileNameW(NULL, exePath, MAX_PATH);

      DWORD verHandle = 0;
      UINT size = 0;
      LPBYTE lpBuffer = NULL;
      DWORD verSize = GetFileVersionInfoSizeW(exePath, &verHandle);
      if (verSize == NULL)
      {
        result->Error("VersionError", "Unable to get version size.");
        return;
      }

      std::vector<BYTE> verData(verSize);
      if (!GetFileVersionInfoW(exePath, verHandle, verSize, verData.data()))
      {
        result->Error("VersionError", "Unable to get version info.");
        return;
      }

      // Retrieve translation information
      struct LANGANDCODEPAGE
      {
        WORD wLanguage;
        WORD wCodePage;
      } *lpTranslate;

      UINT cbTranslate = 0;
      if (!VerQueryValueW(verData.data(), L"\\VarFileInfo\\Translation",
                          (LPVOID *)&lpTranslate, &cbTranslate) ||
          cbTranslate < sizeof(LANGANDCODEPAGE))
      {
        result->Error("VersionError", "Unable to get translation info.");
        return;
      }

      // Build the query string using the first translation
      wchar_t subBlock[50];
      swprintf(subBlock, 50, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
               lpTranslate[0].wLanguage, lpTranslate[0].wCodePage);

      if (!VerQueryValueW(verData.data(), subBlock, (LPVOID *)&lpBuffer, &size))
      {
        result->Error("VersionError", "Unable to query version value.");
        return;
      }

      std::wstring productVersion((wchar_t *)lpBuffer);
      size_t plusPos = productVersion.find(L'+');
      if (plusPos != std::wstring::npos && plusPos + 1 < productVersion.length())
      {
        std::wstring buildNumber = productVersion.substr(plusPos + 1);

        // Trim any trailing spaces
        buildNumber.erase(buildNumber.find_last_not_of(L' ') + 1);

        // Convert wchar_t to std::string (UTF-8)
        int size_needed = WideCharToMultiByte(CP_UTF8, 0, buildNumber.c_str(), -1, NULL, 0, NULL, NULL);
        std::string buildNumberStr(size_needed - 1, 0); // Exclude null terminator
        WideCharToMultiByte(CP_UTF8, 0, buildNumber.c_str(), -1, &buildNumberStr[0], size_needed - 1, NULL, NULL);

        result->Success(flutter::EncodableValue(buildNumberStr));
      }
      else
      {
        result->Error("VersionError", "Invalid version format.");
      }
    }
    else
    {
      result->NotImplemented();
    }
  }

} // namespace desktop_updater
