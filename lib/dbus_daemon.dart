import "package:dbus/dbus.dart";
import "package:factory_reset_tools/reboot.dart";

import "dbus_local_object.dart";

class FactoryResetToolsObject extends ComCanonicalOemFactoryResetTools {
  @override
  Future<DBusMethodResponse> getVersion() async {
    return DBusGetPropertyResponse(const DBusString('1.0'));
  }

  @override
  Future<DBusMethodResponse> doReboot(String rebootOption) async {
    await startCommand(rebootOption);
    return DBusMethodSuccessResponse();
  }
}

Future<void> runDBusDaemon() async {
  var client = DBusClient.system();
  await client.requestName('com.canonical.oem.FactoryResetTools');
  await client.registerObject(FactoryResetToolsObject());
}
