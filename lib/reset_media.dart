import 'dart:io';
import 'package:async/async.dart';
import 'package:dbus/dbus.dart';
import 'package:retry/retry.dart';

const fsuuidFilePathDefault = "/etc/reset_partition_fsuuid";

enum ResetMediaCreationStatus {
  initializing,
  copying,
  finalizing,
  finished,
  failed
}

class ResetMediaCreationProgress {
  final ResetMediaCreationStatus status;
  final double? percent;
  final String? errMsg;
  ResetMediaCreationProgress(this.status, this.percent, this.errMsg);
}

class Drive {
  late final DBusRemoteObject object;

  Future<Partition> format() async {
    var formatTableParams = [
      const DBusString("gpt"),
      DBusDict.stringVariant({})
    ];
    await object.callMethod(
        'org.freedesktop.UDisks2.Block', 'Format', formatTableParams);

    var createPartitionParams = [
      const DBusUint64(1048576),
      const DBusUint64(0),
      const DBusString(""),
      const DBusString(""),
      DBusDict.stringVariant({}),
      const DBusString("vfat"),
      DBusDict.stringVariant({
        "label": const DBusString("RESET_MEDIA"),
      }),
    ];
    final response = await object.callMethod(
        'org.freedesktop.UDisks2.PartitionTable',
        'CreatePartitionAndFormat',
        createPartitionParams,
        replySignature: DBusSignature.objectPath);

    final objectPath = response.returnValues[0].asObjectPath();
    final partition = Partition(DBusRemoteObject(DBusClient.system(),
        name: 'org.freedesktop.UDisks2', path: objectPath));
    return partition;
  }

  Future<void> unmountAndRemoveAll() async {
    final dbusClient = DBusClient.system();
    try {
      final partitions = await object.getProperty(
          'org.freedesktop.UDisks2.PartitionTable', 'Partitions',
          signature: DBusSignature('ao'));
      for (final partitionObjectPath in partitions.asObjectPathArray()) {
        final partition = Partition(DBusRemoteObject(dbusClient,
            name: 'org.freedesktop.UDisks2', path: partitionObjectPath));
        try {
          await partition.unmount();
        } on DBusErrorException {
          // Partition might not have filesystem, or is already unmounted
        }
        await partition.delete();
      }
    } on DBusInvalidArgsException {
      // partition table might not be in the block device
    }
  }

  Drive(this.object);

  static Future<Drive> fromDevicePath(String devicePath) async {
    final dbusClient = DBusClient.system();

    final blockDevicesObject = DBusRemoteObject(dbusClient,
        name: 'org.freedesktop.UDisks2',
        path: DBusObjectPath('/org/freedesktop/UDisks2/block_devices'));
    DBusIntrospectNode introspect = await blockDevicesObject.introspect();

    // iterate through block devices, to find the reset partition
    for (final node in introspect.children) {
      final objectPath =
          DBusObjectPath('/org/freedesktop/UDisks2/block_devices/${node.name}');
      final object = DBusRemoteObject(dbusClient,
          name: 'org.freedesktop.UDisks2', path: objectPath);

      final dp = await object.getProperty(
          'org.freedesktop.UDisks2.Block', 'Device',
          signature: DBusSignature('ay'));
      final dpString =
          String.fromCharCodes(dp.asByteArray().where((e) => e != 0), 0, 128);

      if (dpString == devicePath) {
        return Drive(object);
      }
    }
    throw Exception("cannot find target device");
  }
}

class Partition {
  final DBusRemoteObject object;
  String? _devicePath;

  Future<String> mount() async {
    var result = await object.callMethod(
        'org.freedesktop.UDisks2.Filesystem',
        'Mount',
        [
          DBusDict.stringVariant({"options": const DBusString("noatime")}),
        ],
        replySignature: DBusSignature.string);
    var resultPath = result.returnValues[0].asString();

    return resultPath;
  }

  Future<void> unmount() async {
    await retry(
      () => object.callMethod('org.freedesktop.UDisks2.Filesystem', 'Unmount',
          [DBusDict.stringVariant({})]),
      retryIf: (e) =>
          e is DBusMethodResponseException &&
          e.errorName == "org.freedesktop.UDisks2.Error.DeviceBusy",
    );
  }

  Future<void> delete() async {
    await object.callMethod(
      'org.freedesktop.UDisks2.Partition',
      'Delete',
      [
        DBusDict.stringVariant({}),
      ],
    );
  }

  Future<String> devicePath() async {
    if (_devicePath != null) {
      return _devicePath!;
    }
    final dp = await object.getProperty(
        'org.freedesktop.UDisks2.Block', 'Device',
        signature: DBusSignature('ay'));
    _devicePath =
        String.fromCharCodes(dp.asByteArray().where((e) => e != 0), 0, 128);
    return _devicePath!;
  }

  Partition(this.object);
}

Future<Partition> getResetPartition(
    {fsuuidFilePath = fsuuidFilePathDefault}) async {
  var targetFSUUID = await File(fsuuidFilePath).readAsString();
  targetFSUUID = targetFSUUID.trim();
  var dbusClient = DBusClient.system();

  final blockDevicesObject = DBusRemoteObject(dbusClient,
      name: 'org.freedesktop.UDisks2',
      path: DBusObjectPath('/org/freedesktop/UDisks2/block_devices'));
  DBusIntrospectNode introspect = await blockDevicesObject.introspect();

  // iterate through block devices, to find the reset partition
  DBusRemoteObject? targetObject;
  for (final node in introspect.children) {
    final blockDeviceObjectPath =
        DBusObjectPath('/org/freedesktop/UDisks2/block_devices/${node.name}');
    final blockDeviceObject = DBusRemoteObject(dbusClient,
        name: 'org.freedesktop.UDisks2', path: blockDeviceObjectPath);

    final fsuuid = await blockDeviceObject.getProperty(
        'org.freedesktop.UDisks2.Block', 'IdUUID',
        signature: DBusSignature('s'));
    if (fsuuid.asString() == targetFSUUID) {
      targetObject = blockDeviceObject;
      break;
    }
  }

  if (targetObject == null) {
    throw Exception("reset partition not found");
  }

  return Partition(targetObject);
}

Future<int?> getFsUsedSize(String devicePath) async {
  final process =
      await Process.run("lsblk", ["-b", "-n", "-o", "FSUSED", devicePath]);
  return int.tryParse(process.stdout as String);
}

Stream<double> copyPercentageUpdate(
    Partition resetPartition, targetPartition) async* {
  final int total = (await getFsUsedSize(await resetPartition.devicePath()))!;
  int used = 0;
  double percent = 0;
  while (true) {
    used = (await getFsUsedSize(await targetPartition.devicePath())) ?? used;
    double newPercent = used / total;
    if (newPercent > 1) {
      percent = 1;
    } else if (newPercent > percent) {
      percent = newPercent;
    }
    yield percent;
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

Stream<ResetMediaCreationProgress> copyAsyncJob(Partition resetPartition,
    targetPartition, String rpPath, targetPath) async* {
  yield ResetMediaCreationProgress(
      ResetMediaCreationStatus.copying, null, null);

  var result = await Process.start(
      "rsync", ["-a", "--no-links", "$rpPath/", targetPath]);
  var exitCode = await result.exitCode;
  if (exitCode != 0) {
    yield ResetMediaCreationProgress(
        ResetMediaCreationStatus.failed, null, "failed to copy files");
  }

  yield ResetMediaCreationProgress(
      ResetMediaCreationStatus.finalizing, null, null);

  result = await Process.start("/bin/bash",
      ["$targetPath/cloud-configs/on-create-media.sh", targetPath]);
  if (exitCode != 0) {
    yield ResetMediaCreationProgress(ResetMediaCreationStatus.failed, null,
        "failed to run script after media creation");
  }
  try {
    await resetPartition.unmount();
    await targetPartition.unmount();
  } catch (e) {
    yield ResetMediaCreationProgress(ResetMediaCreationStatus.failed, null,
        "failed to unmount: ${e.toString()}");
  }

  yield ResetMediaCreationProgress(
      ResetMediaCreationStatus.finished, null, null);
}

Stream<ResetMediaCreationProgress> createResetMedia(
    String targetDevicePath) async* {
  var progress = ResetMediaCreationProgress(
      ResetMediaCreationStatus.initializing, null, null);
  yield progress;

  final tmpDir = Directory("/tmp").createTempSync("reset-media-");

  tmpDir.deleteSync();

  final resetPartition = await getResetPartition();
  final rpPath = await resetPartition.mount();

  final targetDrive = await Drive.fromDevicePath(targetDevicePath);
  await targetDrive.unmountAndRemoveAll();
  final targetPartition = await targetDrive.format();
  final targetPath = await targetPartition.mount();

  final copyJob =
      copyAsyncJob(resetPartition, targetPartition, rpPath, targetPath);
  final copyPercentage = copyPercentageUpdate(resetPartition, targetPartition);
  final mergedStreams = StreamGroup.merge([copyJob, copyPercentage]);

  await for (var r in mergedStreams) {
    if (r is double) {
      // copyPercentage
      progress =
          ResetMediaCreationProgress(progress.status, r, progress.errMsg);
      yield progress;
    } else if (r is ResetMediaCreationProgress) {
      // copyJob
      progress =
          ResetMediaCreationProgress(r.status, progress.percent, r.errMsg);
      yield progress;
      if (r.status == ResetMediaCreationStatus.finished ||
          r.status == ResetMediaCreationStatus.failed) {
        break;
      }
    }
  }
}
