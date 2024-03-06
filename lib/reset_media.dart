import 'dart:io';
import 'package:dbus/dbus.dart';

const fsuuidFilePathDefault = "/etc/reset_partition_fsuuid";

enum ResetMediaCreationStatus { initializing, copying, finalizing, finished }

class ResetMediaCreationProgress {
  final ResetMediaCreationStatus status;
  final double progress;
  ResetMediaCreationProgress(this.status, this.progress);
}

var udevCallParams = [
  DBusDict.stringVariant({"auth.no_user_interaction": const DBusBoolean(true)})
];

class Drive {
  final String deviceName;
  late final DBusRemoteObject object;

  Future<void> format() async {
    var formatFilesystemParams = [
      const DBusString("vfat"),
      DBusDict.stringVariant({
        "auth.no_user_interaction": const DBusBoolean(true),
        "update-partition-type": const DBusBoolean(true),
        "label": const DBusString("RESET_MEDIA"),
      })
    ];
    await object.callMethod(
        'org.freedesktop.UDisks2.Block', 'Format', formatFilesystemParams,
        replySignature: DBusSignature.string);
  }

  unmount() async {
    await object.callMethod(
        'org.freedesktop.UDisks2.Filesystem', 'Unmount', udevCallParams,
        noReplyExpected: true);
  }

  Drive(this.deviceName) {
    var dbusClient = DBusClient.system();
    final blockDeviceObjectPath =
        DBusObjectPath('/org/freedesktop/UDisks2/block_devices/$deviceName');
    object = DBusRemoteObject(dbusClient,
        name: 'org.freedesktop.UDisks2', path: blockDeviceObjectPath);
  }
}

class Filesystem {
  final DBusRemoteObject object;

  Future<String> mount() async {
    var result = await object.callMethod(
        'org.freedesktop.UDisks2.Filesystem', 'Mount', udevCallParams,
        replySignature: DBusSignature.string);
    var resultPath = result.returnValues[0].asString();

    return resultPath;
  }

  unmount() async {
    await object.callMethod(
        'org.freedesktop.UDisks2.Filesystem', 'Unmount', udevCallParams,
        noReplyExpected: true);
  }

  Filesystem(this.object);
}

Future<Filesystem> getResetPartition(
    {fsuuidFilePath = fsuuidFilePathDefault}) async {
  var targetFSUUID = await File(fsuuidFilePath).readAsString();
  var dbusClient = DBusClient.system();

  final blockDevicesObject = DBusRemoteObject(dbusClient,
      name: 'org.freedesktop.UDisks2',
      path: DBusObjectPath('/org/freedesktop/UDisks2/block_devices'));
  DBusIntrospectNode introspect = await blockDevicesObject.introspect();

  // iterate through block devices, to find out devices that
  DBusRemoteObject? targetObject;
  for (final node in introspect.children) {
    final blockDeviceObjectPath =
        DBusObjectPath('/org/freedesktop/UDisks2/block_devices/${node.name}');
    final blockDeviceObject = DBusRemoteObject(dbusClient,
        name: 'org.freedesktop.UDisks2', path: blockDeviceObjectPath);

    final fsuuid = await blockDeviceObject.getProperty(
        'org.freedesktop.UDisks2.Block', 'IdUUID',
        signature: DBusSignature('s'));
    if (fsuuid.asString() != targetFSUUID) {
      targetObject = blockDeviceObject;
      break;
    }
  }

  if (targetObject == null) {
    throw Exception("reset partition not found");
  }

  return Filesystem(targetObject);
}

Stream<ResetMediaCreationProgress> createResetMedia() async* {
  yield ResetMediaCreationProgress(ResetMediaCreationStatus.initializing, 0);

  final tmpDir = Directory("/tmp").createTempSync("reset-media-");

  tmpDir.deleteSync();

  var resetPartition = await getResetPartition();
  var rpPath = await resetPartition.mount();

/*
func formatAndMountMedia(devPath, mediaDir string) (partDev *lsblk.BlockDevice, err error) {
	dev := lsblk.GetDevice(devPath)
	if dev == nil {
		return nil, fmt.Errorf("cannot get device %s", devPath)
	}

	err = unmountAllParts(dev)
	if err != nil {
		return nil, fmt.Errorf("cannot unmount device %s: %w", devPath, err)
	}

	partDev, err = formatResetMedia(devPath)
	if err != nil {
		return nil, fmt.Errorf("cannot format device %s: %w", devPath, err)
	}

	err = mounter.Mount(partDev.Path, mediaDir, "", []string{"rw", "noatime"})
	if err != nil {
		return nil, fmt.Errorf("cannot mount partition: %w", err)
	}
	return partDev, nil
}
*/
}

/* TODO: the following Go source code needs translation

package createmedia

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
	"strings"
	"strconv"

	"github.com/canonical/ubuntu-oem-media-creator/internal/lsblk"
	"k8s.io/mount-utils"
)

var ErrNoRootPartition = errors.New("cannot find root partition")
var ErrNoResetPartition = errors.New("cannot find reset partition")
var microsoftReservedPartitionUUID = "e3c9e316-0b5c-4db8-817d-f92df00215ae"

var mounter = mount.New("")

type Status struct {
	Progress float32 `json:"progress"`
	Status   string  `json:"status"`
}

func CreateMedia(device string, status chan Status) error {
	// Create progres channel early so the the status is updated during
	// unmount sync
	progressChan := make(chan string, 1)
	defer close(progressChan)

	status <- Status{
		Progress: 0,
		Status:   "initializing",
	}

	dir, err := os.MkdirTemp("", "reset-media-*")
	if err != nil {
		return fmt.Errorf("cannot create tempdir for mounting: %w", err)
	}
	defer os.RemoveAll(dir)
	rpDir := filepath.Join(dir, "rp")
	mediaDir := filepath.Join(dir, "media")
	err = os.MkdirAll(rpDir, 0755)
	if err != nil {
		return fmt.Errorf("cannot create tempdir/rp for mounting: %w", err)
	}
	err = os.MkdirAll(mediaDir, 0755)
	if err != nil {
		return fmt.Errorf("cannot create tempdir/media for mounting: %w", err)
	}

	var srcDev *lsblk.BlockDevice
	srcDev, err = mountResetPartition(rpDir)
	if err != nil {
		return fmt.Errorf("cannot mount reset partition: %w", err)
	}
	defer unmount(rpDir)

	partDev, err := formatAndMountMedia(device, mediaDir)
	if err != nil {
		return fmt.Errorf("cannot mount media: %w", err)
	}
	defer unmount(mediaDir)

	go func() {
		oldProgress := float32(0)
		// device might be unmounted but syncing, therefore we need to
		// cache the final size
		total := int64(0)
		used := int64(0)
		statusText := "copying"
		for {
			time.Sleep(500 * time.Millisecond)
			if total == 0 {
				updateSrcDev := lsblk.GetDevice(srcDev.Path)
				total = updateSrcDev.FSUsed
				continue
			}
			updateTgtDev := lsblk.GetDevice(partDev.Path)
			if updateTgtDev.FSUsed != 0 {
				used = updateTgtDev.FSUsed
			}
			select {
			case newStatusText, ok := <-progressChan:
				if !ok {
					return
				}
				statusText = newStatusText
			default:
			}
			dirtyInfoByte, _ := exec.Command("grep", "-e", "Dirty:", "/proc/meminfo").Output()
			dirty, _ := strconv.ParseInt(strings.Fields(string(dirtyInfoByte))[1], 10, 64)
			dirty = dirty << 10

			completed := used-dirty

			progress := float32(completed) / float32(total)
			if progress < oldProgress {
				progress = oldProgress
			}
			if progress > 1 {
				progress = 1
			}
			oldProgress = progress

			status <- Status{
				Progress: progress,
				Status:   statusText,
			}
		}
	}()

	err = copyContent(rpDir, mediaDir)
	if err != nil {
		return fmt.Errorf("cannot copy content: %w", err)
	}

	progressChan <- "finalizing"

	err = runScript(mediaDir)
	if err != nil {
		log.Printf("cannot run script for creating reset media: %v", err)
	}

	return nil
}

func getResetPartition() (*lsblk.BlockDevice, error) {
	blkDevs := lsblk.GetDevices()
	rootPart := blkDevs.GetDeviceAtMountpoint("/")
	if rootPart == nil {
		return nil, ErrNoRootPartition
	}

	part := rootPart
	for part.Parent != nil {
		part = part.Parent
	}

	for i := range part.Children {
		dev := &part.Children[i]
		if dev.PartType == microsoftReservedPartitionUUID {
			return dev, nil
		}
	}

	return nil, ErrNoResetPartition
}

func mountResetPartition(rpDir string) (*lsblk.BlockDevice, error) {
	blkDev, err := getResetPartition()
	if err != nil {
		return nil, fmt.Errorf("cannot get reset partition: %w", err)
	}

	devPath := filepath.Join("/dev", blkDev.Name)
	err = mounter.Mount(devPath, rpDir, "", []string{"ro"})
	if err != nil {
		return nil, fmt.Errorf("cannot mount partition: %w", err)
	}

	return blkDev, nil
}

func formatAndMountMedia(devPath, mediaDir string) (partDev *lsblk.BlockDevice, err error) {
	dev := lsblk.GetDevice(devPath)
	if dev == nil {
		return nil, fmt.Errorf("cannot get device %s", devPath)
	}

	err = unmountAllParts(dev)
	if err != nil {
		return nil, fmt.Errorf("cannot unmount device %s: %w", devPath, err)
	}

	partDev, err = formatResetMedia(devPath)
	if err != nil {
		return nil, fmt.Errorf("cannot format device %s: %w", devPath, err)
	}

	err = mounter.Mount(partDev.Path, mediaDir, "", []string{"rw", "noatime"})
	if err != nil {
		return nil, fmt.Errorf("cannot mount partition: %w", err)
	}
	return partDev, nil
}

func unmountAllParts(dev *lsblk.BlockDevice) error {
	// XXX: assume we don't have mounting hierachy e.g. part a mounted to
	// "a" and part b mounted to "a/b", since it is unusual for a removable
	// device to have that.

	for i := range dev.Children {
		dev := &dev.Children[i]
		err := unmountAllParts(dev)
		if err != nil {
			return err
		}
	}

	for _, mp := range dev.Mountpoints {
		if mp == "" {
			// lsblk might return null on mountpoint
			continue
		}
		err := mounter.Unmount(mp)
		if err != nil {
			return fmt.Errorf("unable to unmount %s: %w", mp, err)
		}
	}

	return nil
}

func formatResetMedia(devPath string) (*lsblk.BlockDevice, error) {
	err := exec.Command("sgdisk", "-Z", devPath).Run()
	if err != nil {
		return nil, err
	}

	err = exec.Command("sgdisk", "-n", "0:2048:0", devPath).Run()
	if err != nil {
		return nil, err
	}

	blkdev := lsblk.GetDevice(devPath)
	part := blkdev.Children[0]

	err = exec.Command("mkfs.vfat", part.Path).Run()
	if err != nil {
		return nil, err
	}

	return &part, nil
}

func copyContent(rpDir, mediaDir string) error {
	err := exec.Command("rsync", "-a", rpDir+"/", mediaDir).Run()
	if err != nil {
		return err
	}

	return nil
}

func runScript(mediaDir string) error {
	scriptPath := filepath.Join(mediaDir, "cloud-configs", "on-create-media.sh")
	_, err := os.Stat(scriptPath)
	if err != nil {
		return err
	}

	err = exec.Command(scriptPath, mediaDir).Run()
	if err != nil {
		return err
	}

	return nil
}

func unmount(dir string) error {
	return mounter.Unmount(dir)
}

 */
