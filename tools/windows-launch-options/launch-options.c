// Win32 bridge for HotS' own Battle.net launch-options channel.
// Input is an inherited pipe, never argv, environment, files, or log output.
typedef unsigned long DWORD;
typedef unsigned short WCHAR;
typedef void *HANDLE;
typedef struct { DWORD size; unsigned char *bytes; } BLOB;
typedef struct {
 DWORD size; WCHAR *reserved,*desktop,*title;
 DWORD x,y,width,height,xChars,yChars,fill,flags;
 unsigned short show,reservedSize; unsigned char *reservedBytes;
 HANDLE input,output,error;
} STARTUP;
typedef struct { HANDLE process,thread; DWORD processID,threadID; } PROCESS;
#define DLL __declspec(dllimport)
DLL DWORD __stdcall GetLastError(void);
DLL int __stdcall ReadFile(HANDLE,void*,DWORD,DWORD*,void*);
DLL int __stdcall WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
DLL HANDLE __stdcall GetStdHandle(DWORD);
__declspec(noreturn) DLL void __stdcall ExitProcess(unsigned int);
DLL void* __stdcall LocalFree(void*);
DLL int __stdcall CreateProcessW(const WCHAR*,WCHAR*,void*,void*,int,DWORD,void*,const WCHAR*,STARTUP*,PROCESS*);
DLL int __stdcall CloseHandle(HANDLE);
DLL int __stdcall CryptProtectData(BLOB*,const WCHAR*,BLOB*,void*,void*,DWORD,BLOB*);
DLL int __stdcall CryptUnprotectData(BLOB*,WCHAR**,BLOB*,void*,void*,DWORD,BLOB*);
DLL long __stdcall RegCreateKeyExW(HANDLE,const WCHAR*,DWORD,WCHAR*,DWORD,DWORD,void*,HANDLE*,DWORD*);
DLL long __stdcall RegOpenKeyExW(HANDLE,const WCHAR*,DWORD,DWORD,HANDLE*);
DLL long __stdcall RegQueryValueExW(HANDLE,const WCHAR*,DWORD*,DWORD*,unsigned char*,DWORD*);
DLL long __stdcall RegSetValueExW(HANDLE,const WCHAR*,DWORD,DWORD,const unsigned char*,DWORD);
DLL long __stdcall RegDeleteValueW(HANDLE,const WCHAR*);
DLL long __stdcall RegCloseKey(HANDLE);
static unsigned char entropyBytes[16]={0xc8,0x76,0xf4,0xae,0x4c,0x95,0x2e,0xfe,0xf2,0xfa,0x0f,0x54,0x19,0xc0,0x9c,0x43};
static const WCHAR keyPath[]=L"Software\\Blizzard Entertainment\\Battle.net\\Launch Options\\Hero";
static unsigned char input[1024], encrypted[8192];
static STARTUP startup;
static PROCESS child;
static WCHAR command[]=L"\"H:\\Support64\\HeroesSwitcher_x64.exe\" -sso=1 -launch -uid heroes";
static DWORD length(const char *s){DWORD n=0;while(s[n])n++;return n;}
static void clear(void *p,DWORD n){volatile unsigned char *b=p;while(n--)*b++=0;}
static int equal(const char*a,const char*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int ticket(const unsigned char *p,DWORD n){
 if(n<37||n>128||p[2]!='-'||p[35]!='-')return 0;
 for(DWORD i=0;i<2;i++)if(p[i]<'A'||p[i]>'Z')return 0;
 for(DWORD i=3;i<35;i++)if(!((p[i]>='0'&&p[i]<='9')||(p[i]>='a'&&p[i]<='f')||(p[i]>='A'&&p[i]<='F')))return 0;
 for(DWORD i=36;i<n;i++)if(p[i]<'0'||p[i]>'9')return 0;
 return 1;
}
__declspec(noreturn) static void finish(unsigned int status,const char *message){
 clear(input,sizeof(input));clear(encrypted,sizeof(encrypted));
 if(message){DWORD written;WriteFile(GetStdHandle((DWORD)-11),message,length(message),&written,0);}
 // Wine can return 0 when its server disappears. An explicit acknowledgement
 // and this nonzero success code distinguish our completed protocol.
 ExitProcess(status==0?87:status);
}
static char *line(char **p,char *end){
 char *start=*p;while(*p<end&&**p!='\n')(*p)++;
 if(*p==end)return 0;*(*p)++=0;return start;
}
void mainCRTStartup(void){
 DWORD count=0,n=0;
 while(count<sizeof(input)-1){
  if(!ReadFile(GetStdHandle((DWORD)-10),input+count,sizeof(input)-1-count,&n,0)){
   if(GetLastError()!=109)finish(2,"input-failed\n");
   break;
  }
  if(!n)break;
  count+=n;
 }
 if(count==sizeof(input)-1)finish(2,"invalid-input\n");
 for(DWORD i=0;i<count;i++)if(input[i]!='\n'&&(input[i]<32||input[i]>126))finish(2,"invalid-input\n");
 char *p=(char*)input,*end=p+count,*mode=line(&p,end);
 if(!mode)finish(2,"invalid-input\n");
 BLOB entropy={16,entropyBytes},plain={0,0},protected={0,0};
 HANDLE key=0,hkcu=(HANDLE)(long long)(int)0x80000001;
 if(equal(mode,"prepare")&&p==end){
  HANDLE hklm=(HANDLE)(long long)(int)0x80000002;
  DWORD dpi=2,observed=0,type=0,size=sizeof(observed);
  long result=RegCreateKeyExW(hklm,L"Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\HeroesOfTheStorm_x64.exe",0,0,0,0x103,0,&key,0);
  if(!result){
   result=RegSetValueExW(key,L"dpiAwareness",0,4,(const unsigned char*)&dpi,sizeof(dpi));
   if(!result)result=RegQueryValueExW(key,L"dpiAwareness",0,&type,(unsigned char*)&observed,&size);
   RegCloseKey(key);
  }
  finish(result||type!=4||size!=sizeof(dpi)||observed!=dpi?7:0,result||observed!=dpi?"registry-failed\n":"ok\n");
 }
 if(equal(mode,"clear")&&p==end){
  long result=RegOpenKeyExW(hkcu,keyPath,0,0x102,&key);
  if(result==2)finish(0,"ok\n");
  if(!result){result=RegDeleteValueW(key,L"WEB_TOKEN");RegCloseKey(key);}
  finish(result&&result!=2?7:0,result&&result!=2?"registry-failed\n":"ok\n");
 }
 if(equal(mode,"probe")&&p==end){
  DWORD size=sizeof(encrypted),type=0;
  if(RegOpenKeyExW(hkcu,keyPath,0,0x101,&key))finish(3,"missing-options\n");
  long result=RegQueryValueExW(key,L"WEB_TOKEN",0,&type,encrypted,&size);RegCloseKey(key);
  if(result||type!=3)finish(3,"missing-token\n");
  BLOB data={size,encrypted};
  if(!CryptUnprotectData(&data,0,&entropy,0,0,1,&plain))finish(4,"decrypt-failed\n");
  int valid=ticket(plain.bytes,plain.size);clear(plain.bytes,plain.size);LocalFree(plain.bytes);
  finish(valid?0:5,valid?"protected-ticket-valid\n":"invalid-ticket\n");
 }
 int launch=equal(mode,"WAYPOINT-HERO-LAUNCH-1");
 if(!launch&&!equal(mode,"WAYPOINT-HERO-1"))finish(2,"invalid-input\n");
 char *token=line(&p,end),*region=line(&p,end),*locale=line(&p,end);
 if(!token||!region||!locale||p!=end||!ticket((unsigned char*)token,length(token)))finish(2,"invalid-input\n");
 if(!equal(region,"EU")&&!equal(region,"US")&&!equal(region,"KR")&&!equal(region,"CN"))finish(2,"invalid-input\n");
 DWORD localeSize=length(locale);
 if(localeSize!=0&&localeSize!=4)finish(2,"invalid-input\n");
 for(DWORD i=0;i<localeSize;i++)if(!((locale[i]>='A'&&locale[i]<='Z')||(locale[i]>='a'&&locale[i]<='z')))finish(2,"invalid-input\n");
 plain.size=length(token);plain.bytes=(unsigned char*)token;
 if(!CryptProtectData(&plain,0,&entropy,0,0,1,&protected))finish(6,"protect-failed\n");
 BLOB roundtrip={0,0};
 if(!CryptUnprotectData(&protected,0,&entropy,0,0,1,&roundtrip)){clear(protected.bytes,protected.size);LocalFree(protected.bytes);finish(6,"protect-failed\n");}
 int valid=roundtrip.size==plain.size;
 if(valid)for(DWORD i=0;i<plain.size;i++)if(roundtrip.bytes[i]!=plain.bytes[i])valid=0;
 clear(roundtrip.bytes,roundtrip.size);LocalFree(roundtrip.bytes);
 if(!valid){clear(protected.bytes,protected.size);LocalFree(protected.bytes);finish(6,"protect-failed\n");}
 long result=RegCreateKeyExW(hkcu,keyPath,0,0,0,0x103,0,&key,0);
 int launchFailed=0;
 if(!result){
  // Invalidate any previous account before committing the new token last.
  long removed=RegDeleteValueW(key,L"WEB_TOKEN");if(removed&&removed!=2)result=removed;
  WCHAR wideRegion[3]={(WCHAR)region[0],(WCHAR)region[1],0};
  WCHAR wideLocale[5]={0,0,0,0,0};for(DWORD i=0;i<localeSize;i++)wideLocale[i]=(WCHAR)locale[i];
  if(!result)result=RegSetValueExW(key,L"REGION",0,1,(unsigned char*)wideRegion,sizeof(wideRegion));
  if(!result&&localeSize)result=RegSetValueExW(key,L"LOCALE",0,1,(unsigned char*)wideLocale,sizeof(wideLocale));
  if(!result)result=RegSetValueExW(key,L"WEB_TOKEN",0,3,protected.bytes,protected.size);
  if(!result&&launch){
   // Spawn while this client is still connected to the same wineserver.
   // A server crash aborts the hand-off instead of starting with an older
   // token restored from disk in a new server session.
   startup.size=sizeof(startup);
   if(CreateProcessW(L"H:\\Support64\\HeroesSwitcher_x64.exe",command,0,0,0,8,0,L"H:\\",&startup,&child)){
    CloseHandle(child.thread);CloseHandle(child.process);
   }else{result=1;launchFailed=1;}
  }
  if(result)RegDeleteValueW(key,L"WEB_TOKEN");
  RegCloseKey(key);
 }
 clear(protected.bytes,protected.size);LocalFree(protected.bytes);
 finish(launchFailed?8:result?7:0,launchFailed?"launch-failed\n":result?"registry-failed\n":"ok\n");
}
