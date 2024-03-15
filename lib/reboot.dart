import 'package:dbus/dbus.dart';
import 'package:retry/retry.dart';
import 'package:yaml/yaml.dart';
import 'dart:io';
import 'dart:developer';
import "dbus_remote_object.dart";

const defaultFilePath = "/usr/share/desktop-provision/reset.yaml";

sealed class BootOption {
  final String key;
  final String title;
  final String? description;

  BootOption(this.key, this.title, this.description);

  Future<void> run();
}

class GrubBootOption extends BootOption {
  final String optionName;

  GrubBootOption(super.key, super.title, super.description, this.optionName);

  @override
  Future<void> run() async {
    var result = await Process.run("grub-editenv", [
      "/var/lib/snapd/hostfs/boot/grub/grubenv",
      "set",
      "next_entry=$optionName"
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw result.stderr;
    }

    final dbusClient = DBusClient.system();

    final loginObject = DBusRemoteObject(dbusClient,
        name: 'org.freedesktop.login1',
        path: DBusObjectPath('/org/freedesktop/login1'));
    loginObject.callMethod(
        "org.freedesktop.login1.Manager", "Reboot", [const DBusBoolean(true)]);
  }
}

class RunCommandBootOption extends BootOption {
  final List<String> command;

  RunCommandBootOption(super.key, super.title, super.description, this.command);

  @override
  Future<void> run() async {
    var result = await Process.run(command[0], command.sublist(1));
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode == 126) {
      throw "unauthorized";
    }
  }
}

final List<BootOption> defaultBootOption = [
  GrubBootOption(
      "default",
      "Restore Ubuntu to factory state",
      "This option will restore Ubuntu to factory default, removing all files stored in this system during the process.",
      "Restore Ubuntu to factory state"),
  GrubBootOption(
      "fwsetup",
      "UEFI Firmware Settings",
      "Reboot into UEFI Firmware (BIOS) Settings menu",
      "UEFI Firmware Settings"),
];

List<BootOption> getResetOptions({String path = defaultFilePath}) {
  try {
    var rawConfig = File(path).readAsStringSync();
    var config = loadYaml(rawConfig, sourceUrl: Uri.file(path));
    var options = config["reset_tool_options"];
    List<BootOption> bootOptions = [];
    for (YamlMap item in options) {
      if (item.containsKey("grub_option")) {
        bootOptions.add(GrubBootOption(
          item["key"],
          item["title"],
          item["description"],
          item["grub_option"],
        ));
      } else if (item.containsKey("run_command")) {
        final rawCommand = item["run_command"];
        List<String> command;
        if (rawCommand is YamlList) {
          command = rawCommand.cast<String>();
        } else {
          command = ["/usr/bin/bash", "-c", rawCommand as String];
        }

        bootOptions.add(RunCommandBootOption(
          item["key"],
          item["title"],
          item["description"],
          command,
        ));
      }
    }
    assert(bootOptions.isNotEmpty);
    return bootOptions;
  } catch (e) {
    // Generic catch-all exception
    log("reading $path for options failed", error: e);
    return defaultBootOption;
  }
}

Future<void> startCommand(String key, {String path = defaultFilePath}) {
  BootOption option;
  final options = getResetOptions(path: path);

  try {
    option = options.firstWhere((option) => option.key == key);
  } on StateError {
    throw StateError("option not found");
  }

  return option.run();
}

Future<void> startCommandViaDbus(String key,
    {String path = defaultFilePath}) async {
  final dbusClient = DBusClient.system();
  final object = ComCanonicalOemFactoryResetTools(
      dbusClient, 'com.canonical.oem.FactoryResetTools');

  // as service is activated by dbus call, we should try to rerun if dbus gives
  // error
  const retryRunner = RetryOptions(maxAttempts: 5);
  await retryRunner.retry(
    () => object.callReboot(key),
    retryIf: (e) =>
        e is DBusMethodResponseException &&
        e.errorName == "org.freedesktop.DBus.Error.UnknownObject",
  );
}
