import 'package:yaml/yaml.dart';
import 'dart:io';
import 'dart:developer';

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
    List<String> params;
    params = ["/usr/sbin/grub-reboot", optionName];

    var result = await Process.run("/usr/bin/pkexec", params);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode == 126) {
      throw "unauthorized";
    } else if (result.exitCode != 0) {
      throw result.stderr;
    }

    result = await Process.run("/usr/bin/systemctl", ["reboot"]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }
}

class RunCommandBootOption extends BootOption {
  final List<String> command;

  RunCommandBootOption(super.key, super.title, super.description, this.command);

  @override
  Future<void> run() async {
    var result = await Process.run("/usr/bin/pkexec", command);
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
  List<BootOption> options;
  BootOption option;
  options = getResetOptions(path: path);

  try {
    option = options.firstWhere((option) => option.key == key);
  } on StateError {
    throw StateError("option not found");
  }

  return option.run();
}
