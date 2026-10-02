import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/core/storage/token_storage.dart';

// 自建 Dio 实例指向本机回环服务，不依赖 --dart-define，可直接 flutter test 跑。
/// 与生产 dioProvider 同构（同拦截器栈），仅 baseUrl 指向本机回环测试服务。
final testDioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:18764'));
  // baseUrl 一并传给拦截器：refresh 的裸客户端也必须指向同一测试服务
  dio.interceptors.add(AuthInterceptor(ref, baseUrl: 'http://127.0.0.1:18764'));
  return dio;
});

void main(){
  test('AUTH successful refresh plus business 400 must preserve new tokens', () async {
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,18764);
    addTearDown(()=>server.close(force:true));
    server.listen((r) async {
      await r.drain<void>();
      r.response.headers.contentType=ContentType.json;
      if(r.uri.path.endsWith('/refresh')) {
        r.response.write(jsonEncode({'data':{'access_token':'new','refresh_token':'new-refresh'}}));
      } else if(r.headers.value('authorization')=='Bearer old') {
        r.response.statusCode=401;r.response.write('{}');
      } else {
        r.response.statusCode=400;r.response.write(jsonEncode({'message':'business validation failed'}));
      }
      await r.response.close();
    });
    final storage=MemoryTokenStorage()..access='old'..refresh='old-refresh';
    final container=ProviderContainer(overrides:[tokenStorageProvider.overrideWithValue(storage)]);
    addTearDown(container.dispose);
    final dio=container.read(testDioProvider);
    try{await dio.post('/api/business',data:{'invalid':true});}on DioException catch(e){
      expect(e.response?.statusCode,400,reason:'surface actual business failure');
    } finally {
      expect(storage.access,'new',reason:'refresh was accepted; business 400 must not log out');
    }
  });
  test('AUTH multipart upload must be replayable after refresh', () async {
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,18764);
    addTearDown(()=>server.close(force:true));
    var uploads=0;
    server.listen((r) async {
      await r.drain<void>();
      r.response.headers.contentType=ContentType.json;
      if(r.uri.path.endsWith('/refresh')) {
        r.response.write(jsonEncode({'data':{'access_token':'new','refresh_token':'new-refresh'}}));
      } else {
        uploads++;
        r.response.statusCode=r.headers.value('authorization')=='Bearer old'?401:200;
        r.response.write(jsonEncode({'data':{'ok':true}}));
      }
      await r.response.close();
    });
    final storage=MemoryTokenStorage()..access='old'..refresh='old-refresh';
    final container=ProviderContainer(overrides:[tokenStorageProvider.overrideWithValue(storage)]);
    addTearDown(container.dispose);
    final dio=container.read(testDioProvider);
    final response=await dio.post('/api/upload',
      data:FormData.fromMap({'file':MultipartFile.fromBytes([1,2,3],filename:'synthetic.txt')}));
    expect(response.statusCode,200);expect(uploads,2);
  });
}
