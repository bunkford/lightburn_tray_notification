/* lightburn_win_cred.c
 * Thin wrapper around the Windows Credential Manager (advapi32) for storing
 * the SMTP password securely. Compiled by Nim via {.compile.} in
 * lightburn_tray.nim so that all struct layout complexity stays in C.
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <wincred.h>
#include <string.h>

static const WCHAR kCredTarget[] = L"LightBurnMonitor/smtp";
static char gWinPwBuf[1024];

/* Save password to Credential Manager. Pass "" to delete the stored credential. */
void win_save_credential(const char *password) {
    if (!password || password[0] == '\0') {
        CredDeleteW(kCredTarget, CRED_TYPE_GENERIC, 0);
        return;
    }
    CREDENTIALW cred;
    ZeroMemory(&cred, sizeof(cred));
    cred.Type               = CRED_TYPE_GENERIC;
    cred.TargetName         = (LPWSTR)kCredTarget;
    cred.CredentialBlobSize = (DWORD)strlen(password);
    cred.CredentialBlob     = (LPBYTE)password;
    cred.Persist            = CRED_PERSIST_LOCAL_MACHINE;
    CredWriteW(&cred, 0);
}

/* Load password from Credential Manager.  Returns pointer to a static buffer
 * (valid until next call).  Returns "" if no credential is stored. */
const char *win_load_credential(void) {
    PCREDENTIALW pcred = NULL;
    gWinPwBuf[0] = '\0';
    if (CredReadW(kCredTarget, CRED_TYPE_GENERIC, 0, &pcred) && pcred != NULL) {
        DWORD sz = pcred->CredentialBlobSize;
        if (sz >= sizeof(gWinPwBuf)) sz = sizeof(gWinPwBuf) - 1;
        memcpy(gWinPwBuf, pcred->CredentialBlob, sz);
        gWinPwBuf[sz] = '\0';
        CredFree(pcred);
    }
    return gWinPwBuf;
}
