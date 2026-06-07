// Bridging header that exposes the Go proxy core's C API to Swift.
//
// The header below is produced by `core/build-xcframework.sh`
// (`go build -buildmode=c-archive` emits `libtgwsproxy.h`) and ships inside
// TgWsProxyCore.xcframework. Linking the xcframework puts the header on the
// search path so this import resolves.
//
// Exposed functions (see core/tg-ws-proxy.go and core/ios_bridge.go):
//   int   StartProxy(char* host, int port, char* dcIps, char* secret, int verbose);
//   int   StopProxy(void);
//   void  SetPoolSize(int size);
//   void  SetSecret(char* secret);
//   void  SetFakeTls(int enabled, char* domain);
//   void  SetCfProxyConfig(int enabled, int priority, char* userDomain);
//   void  SetCfProxyCacheDir(char* cacheDir);
//   char* GetStats(void);
//   char* GetStatsRu(void);
//   char* GetSecretWithPrefix(void);
//   char* GetLogs(void);
//   void  ClearLogs(void);
//   void  FreeString(char* p);

#import "libtgwsproxy.h"
