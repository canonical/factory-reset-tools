/*
 * Command line entrypoint of factory-reset-tools
 */

import 'dart:io';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:factory_reset_tools/dbus_daemon.dart';
import 'package:factory_reset_tools/reboot.dart';
import 'package:factory_reset_tools/reset_media.dart';

class CreateResetMediaCommand extends Command {
  @override
  final name = "create-reset-media";
  @override
  final description = "Create a reset media from reset partition";

  CreateResetMediaCommand() {
    argParser.addOption(
      "rp-uuid",
      help: "Use another reset partition filesystem UUID",
      valueHelp: "1234-ABCD",
    );
  }

  @override
  void run() async {
    ArgResults argResults = this.argResults!;
    String? fsuuid = argResults['fsuuid'];
    await for (final status
        in createResetMedia(argResults.rest[0], fsuuid: fsuuid)) {
      stdout.writeln(
          "${(status.percent ?? 0.0).toStringAsFixed(2)} ${status.status.toString()} ${status.errMsg ?? ""}");
    }
  }
}

class RebootCommand extends Command {
  @override
  final name = "reboot";
  @override
  final description =
      "Reboot into reset partition, or any other preconfigured options";

  RebootCommand() {
    argParser.addFlag("list",
        abbr: "l", help: "List available reboot options", negatable: false);
  }

  @override
  void run() {
    var argResults = this.argResults!;
    if (argResults['list'] == true) {
      List<BootOption> options = getResetOptions();
      stdout.writeln("List of available options:\n");
      for (BootOption option in options) {
        stdout.writeln("${option.key}: ${option.title}");
        if (option.description != null) {
          stdout.writeln("  ${option.description}");
        }
        stdout.writeln("");
      }
      return;
    }
    startCommand(argResults.rest[0]);
  }
}

class DBusCommand extends Command {
  @override
  final name = "dbus";
  @override
  final description = "Starts a DBus daemon";
  @override
  final hidden = true;

  DBusCommand();

  @override
  void run() async {
    await runDBusDaemon();
  }
}

void main(List<String> args) async {
  final runner = CommandRunner(
      "factory-reset-tools-cli", "Command line utility for factory reset.")
    ..addCommand(CreateResetMediaCommand())
    ..addCommand(RebootCommand())
    ..addCommand(DBusCommand());
  await runner.run(args);
}
