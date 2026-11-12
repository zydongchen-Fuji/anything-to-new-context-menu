// ContextMenuBridge.dll - a tiny native IExplorerCommand handler for the Windows 11 context menu.
//
// One copy of this DLL lives in each package folder next to a bridge.ini that says what the
// menu item is and what it does when clicked:
//
//   [Command]
//   Clsid={...}                  CLSID declared for this verb in AppxManifest.xml
//   Title=Combine Files In Revu  text shown in the menu
//   Icon=C:\path\app.exe,0       optional icon resource
//   Mode=handler | command
//
//   ; Mode=handler: forward the click to an existing legacy IContextMenu shell extension
//   HandlerClsid={...}           CLSID of the legacy handler (HKCR\CLSID\{...})
//   Match=Combine Files          substring of the legacy item's text ('&' ignored, case-insensitive)
//
//   ; Mode=command: launch a program with the selected paths
//   Program=C:\path\app.exe
//   Arguments=%*                 %* = all selected paths (quoted), %1 = first path (quoted)
//
// Errors are appended to error.log next to the DLL.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <new>

static HMODULE g_module = nullptr;
static LONG g_refs = 0;

static const GUID BHID_DataObj = {0xb8c0bd9f, 0xed24, 0x455c, {0x83, 0xe6, 0xd5, 0x39, 0x0c, 0x4f, 0xe8, 0xc4}};

struct Config {
    bool loaded = false;
    CLSID clsid = {};
    CLSID handler = {};
    bool commandMode = false;
    wchar_t title[256] = {};
    wchar_t icon[MAX_PATH + 16] = {};
    wchar_t match[256] = {};
    wchar_t program[MAX_PATH] = {};
    wchar_t arguments[1024] = {};
};
static Config g_cfg;

static void ModuleDirFile(const wchar_t* name, wchar_t* out)
{
    GetModuleFileNameW(g_module, out, MAX_PATH);
    PathRemoveFileSpecW(out);
    PathAppendW(out, name);
}

static void Log(const wchar_t* msg, HRESULT hr)
{
    wchar_t path[MAX_PATH];
    ModuleDirFile(L"error.log", path);
    HANDLE f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    wchar_t line[1024];
    SYSTEMTIME t; GetLocalTime(&t);
    int n = wsprintfW(line, L"%04d-%02d-%02d %02d:%02d:%02d  %s  hr=0x%08X\r\n",
                      t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, msg, (unsigned)hr);
    DWORD w; WriteFile(f, line, n * sizeof(wchar_t), &w, nullptr);
    CloseHandle(f);
}

static const Config& Cfg()
{
    if (g_cfg.loaded) return g_cfg;
    wchar_t ini[MAX_PATH], buf[128];
    ModuleDirFile(L"bridge.ini", ini);
    const wchar_t* s = L"Command";
    GetPrivateProfileStringW(s, L"Clsid", L"", buf, 128, ini);
    CLSIDFromString(buf, &g_cfg.clsid);
    GetPrivateProfileStringW(s, L"HandlerClsid", L"", buf, 128, ini);
    CLSIDFromString(buf, &g_cfg.handler);
    GetPrivateProfileStringW(s, L"Mode", L"handler", buf, 128, ini);
    g_cfg.commandMode = lstrcmpiW(buf, L"command") == 0;
    GetPrivateProfileStringW(s, L"Title", L"", g_cfg.title, 256, ini);
    GetPrivateProfileStringW(s, L"Icon", L"", g_cfg.icon, MAX_PATH + 16, ini);
    GetPrivateProfileStringW(s, L"Match", L"", g_cfg.match, 256, ini);
    GetPrivateProfileStringW(s, L"Program", L"", g_cfg.program, MAX_PATH, ini);
    GetPrivateProfileStringW(s, L"Arguments", L"%*", g_cfg.arguments, 1024, ini);
    g_cfg.loaded = true;
    return g_cfg;
}

// ---------- Mode=handler: drive the legacy IContextMenu ----------

static int FindItem(HMENU m, const wchar_t* match)
{
    int count = GetMenuItemCount(m);
    for (int i = 0; i < count; i++) {
        if (HMENU sub = GetSubMenu(m, i)) {
            int r = FindItem(sub, match);
            if (r >= 0) return r;
            continue;
        }
        wchar_t raw[512], text[512];
        if (!GetMenuStringW(m, i, raw, 512, MF_BYPOSITION)) continue;
        int k = 0;
        for (int j = 0; raw[j] && k < 511; j++) if (raw[j] != L'&') text[k++] = raw[j];
        text[k] = 0;
        if (StrStrIW(text, match)) {
            UINT id = GetMenuItemID(m, i);
            if (id != (UINT)-1) return (int)id;
        }
    }
    return -1;
}

static HRESULT InvokeLegacyHandler(IShellItemArray* items, const Config& c)
{
    IDataObject* data = nullptr;
    IShellExtInit* init = nullptr;
    IContextMenu* cm = nullptr;
    HMENU menu = nullptr;
    HRESULT hr = items->BindToHandler(nullptr, BHID_DataObj, IID_PPV_ARGS(&data));
    if (SUCCEEDED(hr)) hr = CoCreateInstance(c.handler, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&init));
    if (SUCCEEDED(hr)) hr = init->Initialize(nullptr, data, nullptr);
    if (SUCCEEDED(hr)) hr = init->QueryInterface(IID_PPV_ARGS(&cm));
    if (SUCCEEDED(hr)) {
        menu = CreatePopupMenu();
        hr = cm->QueryContextMenu(menu, 0, 1, 0x7FFF, CMF_NORMAL);
    }
    if (SUCCEEDED(hr)) {
        int id = FindItem(menu, c.match);
        if (id < 0) {
            hr = E_FAIL;
            Log(L"legacy menu item not found (check Match in bridge.ini)", hr);
        } else {
            CMINVOKECOMMANDINFO ici = {};
            ici.cbSize = sizeof(ici);
            ici.hwnd = GetForegroundWindow();
            ici.lpVerb = MAKEINTRESOURCEA(id - 1);
            ici.nShow = SW_SHOWNORMAL;
            hr = cm->InvokeCommand(&ici);
        }
    }
    if (menu) DestroyMenu(menu);
    if (cm) cm->Release();
    if (init) init->Release();
    if (data) data->Release();
    return hr;
}

// ---------- Mode=command: launch a program ----------

static bool Append(wchar_t* dst, size_t cap, size_t& len, const wchar_t* s)
{
    size_t n = lstrlenW(s);
    if (len + n + 1 > cap) return false;
    memcpy(dst + len, s, n * sizeof(wchar_t));
    len += n; dst[len] = 0;
    return true;
}

static HRESULT InvokeCommandLine(IShellItemArray* items, const Config& c)
{
    const size_t cap = 32000;
    wchar_t* all = new (std::nothrow) wchar_t[cap];
    wchar_t* args = new (std::nothrow) wchar_t[cap];
    if (!all || !args) { delete[] all; delete[] args; return E_OUTOFMEMORY; }
    all[0] = 0; args[0] = 0;
    wchar_t first[MAX_PATH + 2] = {};
    size_t allLen = 0;

    DWORD count = 0;
    if (items) items->GetCount(&count);
    for (DWORD i = 0; i < count; i++) {
        IShellItem* it = nullptr;
        if (FAILED(items->GetItemAt(i, &it))) continue;
        PWSTR p = nullptr;
        if (SUCCEEDED(it->GetDisplayName(SIGDN_FILESYSPATH, &p))) {
            if (i == 0) wsprintfW(first, L"\"%s\"", p);
            if (allLen) Append(all, cap, allLen, L" ");
            Append(all, cap, allLen, L"\"");
            Append(all, cap, allLen, p);
            Append(all, cap, allLen, L"\"");
            CoTaskMemFree(p);
        }
        it->Release();
    }

    size_t len = 0;
    for (const wchar_t* a = c.arguments; *a; ) {
        if (a[0] == L'%' && a[1] == L'*') { Append(args, cap, len, all); a += 2; }
        else if (a[0] == L'%' && a[1] == L'1') { Append(args, cap, len, first); a += 2; }
        else { wchar_t ch[2] = {*a, 0}; Append(args, cap, len, ch); a++; }
    }

    SHELLEXECUTEINFOW sei = {};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    sei.lpFile = c.program;
    sei.lpParameters = args;
    sei.nShow = SW_SHOWNORMAL;
    HRESULT hr = ShellExecuteExW(&sei) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    delete[] all; delete[] args;
    return hr;
}

// ---------- COM plumbing ----------

class BridgeCommand final : public IExplorerCommand
{
    LONG m_ref = 1;
public:
    BridgeCommand() { InterlockedIncrement(&g_refs); }
    ~BridgeCommand() { InterlockedDecrement(&g_refs); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) {
            *ppv = static_cast<IExplorerCommand*>(this); AddRef(); return S_OK;
        }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_ref); }
    IFACEMETHODIMP_(ULONG) Release() override
    {
        LONG r = InterlockedDecrement(&m_ref);
        if (!r) delete this;
        return r;
    }

    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* name) override { return SHStrDupW(Cfg().title, name); }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override
    {
        if (!Cfg().icon[0]) { *icon = nullptr; return E_NOTIMPL; }
        return SHStrDupW(Cfg().icon, icon);
    }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override { *tip = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* g) override { *g = Cfg().clsid; return S_OK; }
    IFACEMETHODIMP GetState(IShellItemArray*, BOOL, EXPCMDSTATE* s) override { *s = ECS_ENABLED; return S_OK; }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* f) override { *f = ECF_DEFAULT; return S_OK; }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) override { *e = nullptr; return E_NOTIMPL; }

    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override
    {
        const Config& c = Cfg();
        HRESULT hr;
        if (c.commandMode) hr = InvokeCommandLine(items, c);
        else if (!items) hr = E_INVALIDARG;
        else hr = InvokeLegacyHandler(items, c);
        if (FAILED(hr)) Log(c.title, hr);
        return hr;
    }
};

class Factory final : public IClassFactory
{
    LONG m_ref = 1;
public:
    Factory() { InterlockedIncrement(&g_refs); }
    ~Factory() { InterlockedDecrement(&g_refs); }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
        }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_ref); }
    IFACEMETHODIMP_(ULONG) Release() override
    {
        LONG r = InterlockedDecrement(&m_ref);
        if (!r) delete this;
        return r;
    }
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
    {
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        BridgeCommand* c = new (std::nothrow) BridgeCommand();
        if (!c) return E_OUTOFMEMORY;
        HRESULT hr = c->QueryInterface(riid, ppv);
        c->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override
    {
        if (lock) InterlockedIncrement(&g_refs); else InterlockedDecrement(&g_refs);
        return S_OK;
    }
};

extern "C" BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) { g_module = h; DisableThreadLibraryCalls(h); }
    return TRUE;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() { return g_refs == 0 ? S_OK : S_FALSE; }

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv)
{
    *ppv = nullptr;
    if (clsid != Cfg().clsid) return CLASS_E_CLASSNOTAVAILABLE;
    Factory* f = new (std::nothrow) Factory();
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}
