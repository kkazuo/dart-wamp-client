# wamp_client

A library for Dart [WAMP] client.

## Usage

A simple usage example:

    import 'package:wamp_client/wamp_client.dart';

    main() {
      var wamp = new WampClient('your.realm1')
        ..onConnect = (c) {
          c.subscribe('your.topic').then((sub) async {
            await for (var event in sub) {
              ...
            }
          });
        };

      await wamp.connect('ws://localhost:8080/ws');
    }

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/kkazuo/dart-wamp-client/issues
[WAMP]: http://wamp-proto.org
