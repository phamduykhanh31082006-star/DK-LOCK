from pathlib import Path
import json,re,sys,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
checks=[]
def check(n,c,d=''): checks.append((n,bool(c),d))
def text(p): return (ROOT/p).read_text(encoding='utf-8')
required=[
 'V4_SCOPE.md','V4_WORK_STATUS.md','docs/architecture/V4_IMPACT_ANALYSIS.md','docs/security/V4_CONTENT_SECURITY.md','docs/testing/V4_ACCEPTANCE.md','docs/TRACEABILITY_V4.md',
 'src/DKLock.Core/Folders/FolderPolicy.cs','src/DKLock.Core/Documents/SecureDocument.cs','src/DKLock.Core/Encryption/EncryptionContracts.cs',
 'src/DKLock.Data/SqliteFolderPolicyRepository.cs','src/DKLock.Data/SqliteSecureDocumentRepository.cs','src/DKLock.Data/SqliteEncryptionKeyRepository.cs',
 'src/DKLock.Security/Encryption/ChunkedAesGcmFileEncryptionService.cs','src/DKLock.Security/Folders/ProtectedFolderGuard.cs','src/DKLock.Security/Sessions/InMemoryFolderSessionService.cs',
 'src/DKLock.Infrastructure/DpapiMachineKeyProtector.cs','src/DKLock.Service/Content/MachineBoundDataKeyProvider.cs','src/DKLock.Service/Content/FolderProtectionCoordinator.cs','src/DKLock.Service/Content/VaultCoordinator.cs',
 'src/DKLock.App/Dialogs/CredentialPromptWindow.xaml','src/DKLock.App/ViewModels/FoldersViewModel.cs','src/DKLock.App/ViewModels/VaultViewModel.cs',
 'tests/DKLock.V4.ContractTests/Program.cs','tests/DKLock.V4.IntegrationTests/Program.cs','tests/DKLock.V3.RegressionIntegrationTests/Program.cs','scripts/test-v4.ps1','.github/workflows/v4-windows-gate.yml']
for f in required: check('required: '+f,(ROOT/f).is_file())
for p in sorted(list(ROOT.rglob('*.xaml'))+list(ROOT.rglob('*.csproj'))):
    try: ET.parse(p); ok=True; d=''
    except Exception as ex: ok=False; d=str(ex)
    check('xml: '+str(p.relative_to(ROOT)),ok,d)
contract=json.loads(text('config/architecture_contracts.json'))
allowed={x['from']:set(x['may_depend_on']) for x in contract['dependency_rules']}
for module in contract['modules']:
    proj=ROOT/'src'/module/f'{module}.csproj'; check('project: '+module,proj.is_file())
    if proj.exists():
        refs=set(re.findall(r'ProjectReference Include="\.\.\\([^\\]+)\\',proj.read_text(encoding='utf-8')))
        check('dependency exact: '+module,refs==allowed[module],f'{refs} != {allowed[module]}')
core='\n'.join(p.read_text(encoding='utf-8') for p in (ROOT/'src/DKLock.Core').rglob('*.cs'))
for term in ['System.Windows','Microsoft.Data.Sqlite','System.Management','ProtectedData','NtSuspendProcess','AesGcm']:
    check('Core platform boundary: '+term,term not in core)
app='\n'.join(p.read_text(encoding='utf-8') for p in (ROOT/'src/DKLock.App').rglob('*.cs'))
for term in ['System.Diagnostics.Process','Microsoft.Data.Sqlite','SqliteConnection','System.Management','NtSuspendProcess','AesGcm','ProtectedData.Protect']:
    check('UI security boundary: '+term,term not in app)
for term in ['.Wait()','Thread.Sleep','.GetAwaiter().GetResult()']:
    check('UI nonblocking: '+term,term not in app)
ipc=text('src/DKLock.Core/IPC/IpcContracts.cs')
check('IPC V4 current','public const int Version = 4' in ipc)
check('IPC V2/V3 compatibility','MinimumSupportedVersion = 2' in ipc and 'DefaultPipeName = "DKLock.Core.V2"' in ipc)
for cmd in ['get_folders','add_folder','set_folder_enabled','lock_folder','unlock_folder','remove_folder','get_vault_documents','import_vault_document','export_vault_document','remove_vault_document']:
    check('V4 IPC: '+cmd,cmd in ipc)
data=text('src/DKLock.Data/SqliteDatabase.cs')
for marker in ['CREATE TABLE IF NOT EXISTS protected_folders','CREATE TABLE IF NOT EXISTS secure_documents','CREATE TABLE IF NOT EXISTS encryption_keys','UPDATE schema_info SET version = 3','foreign_keys=ON','journal_mode=WAL']:
    check('V4 SQLite: '+marker,marker in data)
enc=text('src/DKLock.Security/Encryption/ChunkedAesGcmFileEncryptionService.cs')
for marker in ['AesGcm','DKLOCK4F','VerifyEncryptedFileAsync','IncrementalHash','CryptographicOperations.ZeroMemory']:
    check('V4 encryption: '+marker,marker in enc)
key=text('src/DKLock.Infrastructure/DpapiMachineKeyProtector.cs')
check('DPAPI LocalMachine','ProtectedData.Protect' in key and 'DataProtectionScope.LocalMachine' in key)
folder=text('src/DKLock.Service/Content/FolderProtectionCoordinator.cs')
for marker in ['VerifyEncryptedFileAsync','File.Delete(source)','LOCK_INCOMPLETE','Unlock collision','LockAllEnabledAsync','ScheduleRelock','FOLDER_UNLOCKED']:
    check('folder safety: '+marker,marker in folder)
vault=text('src/DKLock.Service/Content/VaultCoordinator.cs')
for marker in ['VerifyEncryptedFileAsync','DESTINATION_EXISTS','moveOriginal','VerifyAsync','VAULT_DOCUMENT_EXPORTED']:
    check('vault safety: '+marker,marker in vault)
check('Folders UI activated','Add folder' in text('src/DKLock.App/Views/FoldersView.xaml') and 'IsEnabled="False"' not in text('src/DKLock.App/Views/FoldersView.xaml'))
check('Vault UI activated','Add encrypted copy' in text('src/DKLock.App/Views/VaultView.xaml') and 'Secure move' in text('src/DKLock.App/Views/VaultView.xaml'))
scope=text('V4_SCOPE.md').lower()
for token in ['aes-256-gcm','dpapi','not a kernel','delete plaintext','definition of done','out of scope','service startup/shutdown']:
    check('scope token: '+token,token in scope)
tests=text('tests/DKLock.V4.IntegrationTests/Program.cs')
for marker in ['Wrong folder password is denied','Service stop re-locks enabled folder','Vault export requires valid authentication','Authenticated secure move removes original','Protocol V3 client remains transport-compatible','Activity log contains no supplied authentication secrets']:
    check('V4 E2E: '+marker,marker in tests)
dashboard=text('src/DKLock.App/Views/DashboardView.xaml')
check('Dashboard V4 folder capability truthful','V4 encrypted at rest' in dashboard and 'Planned V4' not in dashboard)
check('Dashboard V4 vault capability truthful','V4 Secure Documents' in dashboard and dashboard.count('Text="Available"') >= 3)
shell=text('src/DKLock.App/MainWindow.xaml')
check('Shell V4 content status truthful','V4 CONTENT PROTECTION' in shell and 'V3 APPLICATION PROTECTION' not in shell)
credential_ui=text('src/DKLock.App/Dialogs/CredentialPromptWindow.xaml')
check('Credential combo selected text contrast',credential_ui.count('Foreground="#111827"') >= 6)
source='\n'.join(p.read_text(encoding='utf-8',errors='ignore') for p in (ROOT/'src').rglob('*') if p.suffix in {'.cs','.xaml','.csproj'})
for marker in ['TODO','FIXME','HACK','throw new NotImplementedException']:
    check('no unfinished marker: '+marker,marker not in source)
passed=sum(x[1] for x in checks); failed=[x for x in checks if not x[1]]
print(f'V4 STATIC VALIDATION: {passed}/{len(checks)} PASS')
for n,_,d in failed: print('FAIL:',n,(':: '+d if d else ''))
sys.exit(1 if failed else 0)
