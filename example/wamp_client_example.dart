import 'dart:async';
import 'package:wamp_client/wamp_client.dart';

Future main() async {
  var wamp = new WampClient('realm1',
      auth: WampAuth.wampcra(
        id: 'client1',
        secret: 'secret123',
      ))
    ..onConnect = (c) {
      c.subscribe('topic').then((s) async {
        await for (final ev in s) {
          print('ev $ev');
          //return;
        }
      });
      print('start sub');

      c.publish('topic').then((dynamic _) {
        print('published');
      });

      final pname = 'proc.17';

      c.register(pname, (a) {
        print('proc arg: $a');
        //throw new WampArgs(<dynamic>[100], <String, dynamic>{'test': true});
        return a;
      }).then((WampRegistration regid) async {
        print('register ok $regid');

        await c.call(pname, <dynamic>[2, 3],
            <String, dynamic>{'hello': 'world!'}).then((r) {
          print('result ${r.args} ${r.params}');
        }).catchError((dynamic e) {
          print('call err $e');
        });

        await c.unregister(regid);
        print('unregister ok');
      }).catchError((dynamic e) {
        print('register error $e');
      });
    };
  await wamp.connect('ws://localhost:8080/ws');
}
