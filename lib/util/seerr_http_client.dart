import 'package:http/http.dart' as http;

http.Client createSeerrHttpClient() => SeerrHttpClient(http.Client());

class SeerrHttpClient extends http.BaseClient {
  final http.Client inner;
  SeerrHttpClient(this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.followRedirects = false;
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}
