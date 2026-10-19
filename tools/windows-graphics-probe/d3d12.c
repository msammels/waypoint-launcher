// Device creation only: no game, window, hooks or rendering workload.
typedef unsigned long DWORD;
typedef long HRESULT;
typedef struct { DWORD a; unsigned short b,c; unsigned char d[8]; } GUID;
__declspec(dllimport) HRESULT __stdcall D3D12CreateDevice(void*,int,const GUID*,void**);
__declspec(dllimport) void* __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(void*,const void*,DWORD,DWORD*,void*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned int);
static const GUID deviceID={0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};
void mainCRTStartup(void){
 void *device=0;DWORD written=0;
 HRESULT result=D3D12CreateDevice(0,0xc000,&deviceID,&device);
 if(result<0||!device){
  char msg[]="device-failed 0x00000000\n";const char *hex="0123456789abcdef";
  for(unsigned int i=0;i<8;i++)msg[16+i]=hex[((DWORD)result>>(28-4*i))&15];
  WriteFile(GetStdHandle((DWORD)-11),msg,sizeof(msg)-1,&written,0);ExitProcess(1);
 }
 typedef DWORD (__stdcall *Release)(void*);
 ((Release)(*(void***)device)[2])(device);
 const char ok[]="device-created\n";
 WriteFile(GetStdHandle((DWORD)-11),ok,sizeof(ok)-1,&written,0);ExitProcess(87);
}
