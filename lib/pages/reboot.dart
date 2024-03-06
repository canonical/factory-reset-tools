import 'package:flutter/material.dart';
import 'package:yaru_widgets/yaru_widgets.dart';
import 'package:ubuntu_wizard/ubuntu_wizard.dart';
import '../reboot.dart';

const defaultOptionKey = "default";

class FactoryReset extends StatefulWidget {
  const FactoryReset({super.key});

  @override
  State<FactoryReset> createState() => _FactoryResetState();
}

class _FactoryResetState extends State<FactoryReset> {
  String _selectedOption = defaultOptionKey;
  List<BootOption> options = [];

  @override
  initState() {
    super.initState();

    options = getResetOptions();
    _selectedOption = options.first.key;
  }

  doExecute(BuildContext context) async {
    try {
      await startCommand(_selectedOption);
    } catch (e) {
      if (!context.mounted) return;
      showDialog<String>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          titlePadding: EdgeInsets.zero,
          title: const YaruDialogTitleBar(
            title: Text('Failed to run command'),
            isClosable: true,
          ),
          content: Text(e.toString()),
          actions: <Widget>[
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Widget buildWithMultipleOptions(BuildContext context) {
    var optionsWidgets = options.map((option) {
      return RadioListTile<String>(
        key: Key(option.key),
        value: option.key,
        groupValue: _selectedOption,
        onChanged: (String? value) =>
            setState(() => _selectedOption = value ?? options.first.key),
        title: Text(option.title),
        subtitle:
            option.description != null ? Text(option.description ?? "") : null,
      );
    }).toList();

    return WizardPage(
        title: const YaruWindowTitleBar(title: Text("Factory Reset Tool")),
        header: const Text("Select an option to start factory reset:"),
        content: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: optionsWidgets,
        ),
        bottomBar: WizardBar(
            leading: OutlinedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text("Back")),
            trailing: [
              NextWizardButton(
                highlighted: true,
                label: "Start",
                onExecute: () => doExecute(context),
              )
            ]));
  }

  Widget buildWithSingleOption(BuildContext context) {
    var option = options.first;
    return WizardPage(
        title: const YaruWindowTitleBar(title: Text("Factory Reset Tool")),
        header: const Text("Are you sure to start the factory reset?"),
        content: Column(mainAxisAlignment: MainAxisAlignment.start, children: [
          ListTile(
            key: Key(option.key),
            title: Text(option.title),
            subtitle: option.description != null
                ? Text(option.description ?? "")
                : null,
          )
        ]),
        bottomBar: WizardBar(
            leading: OutlinedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text("Back")),
            trailing: [
              NextWizardButton(
                highlighted: true,
                label: "Reboot",
                onExecute: () => doExecute(context),
              ),
            ]));
  }

  @override
  Widget build(BuildContext context) {
    if (options.length > 1) {
      return buildWithMultipleOptions(context);
    }
    return buildWithSingleOption(context);
  }
}
