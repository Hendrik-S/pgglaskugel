// Copyright © 2017 Alexander Sosna <alexander@xxor.de>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

package cmd

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	log "github.com/Sirupsen/logrus"
	ec "github.com/xxorde/pgglaskugel/errorcheck"
	util "github.com/xxorde/pgglaskugel/util"
	wal "github.com/xxorde/pgglaskugel/wal"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	// archiveCmd represents the archive command
	archiveCmd = &cobra.Command{
		Use:   "archive WAL_FILE...",
		Short: "Archives given WAL file(s)",
		Long: `This command archives given WAL file(s). This command can be used as an archive_command. The command to recover is "recover". 
	Example: archive_command = "` + myName + ` archive %p"`,
		Run: func(cmd *cobra.Command, args []string) {
			if len(args) < 1 {
				log.Fatal("No WAL file was defined!")
			}
			count := 0
			for _, walSource := range args {
				err := testWalSource(walSource)
				ec.Check(err)
				walName := filepath.Base(walSource)
				err = archiveWal(walSource, walName)
				if err != nil {
					log.Fatal("archive failed ", err)
				}
				count++
			}
			elapsed := time.Since(startTime)
			log.Info("Archived ", count, " WAL file(s) in ", elapsed)
		},
	}
)

func testWalSource(walSource string) (err error) {
	// Get size of backup
	file, err := os.Open(walSource)
	if err != nil {
		return err
	}
	defer file.Close()

	fi, err := file.Stat()
	if err != nil {
		return err
	}

	if fi.Size() < wal.MinArchiveSize {
		return errors.New("Input file to small")
	}

	if fi.Size() > wal.MaxWalSize {
		return errors.New("Input file to big")
	}

	return nil
}

// archiveWal archives a WAL file with the configured method
func archiveWal(walSource string, walName string) (err error) {
	archiveTo := viper.GetString("archive_to")

	switch archiveTo {
	case "file":
		return archiveToFile(walSource, walName)
	case "s3":
		return archiveToS3(walSource, walName)
	default:
		log.Fatal(archiveTo, " no valid value for archiveTo")
	}
	return errors.New("This should never be reached")
}

// archiveToFile uses the shell command lz4 to archive WAL files
func archiveToFile(walSource string, walName string) (err error) {
	walTarget := viper.GetString("archivedir") + "/wal/" + walName + ".zst"
	log.Debug("archiveWithZstdCommand, walSource: ", walSource, ", walName: ", walName, ", walTarget: ", walTarget)

	// Check if WAL file is already in archive
	if _, err := os.Stat(walTarget); err == nil {
		err := errors.New("WAL file is already in archive: " + walTarget)
		return err
	}

	archiveCmd := exec.Command(cmdZstd, walSource, "-o", walTarget)

	// Watch output on stderror
	archiveStderror, err := archiveCmd.StderrPipe()
	ec.Check(err)
	go util.WatchOutput(archiveStderror, log.Warn)

	err = archiveCmd.Run()
	return err
}

// archiveToS3 archives to a S3 compatible object store
func archiveToS3(walSource string, walName string) (err error) {
	bucket := viper.GetString("s3_bucket_wal")
	location := viper.GetString("s3_location")
	walTarget := walName + ".zst"
	encrypt := viper.GetBool("encrypt")
	recipient := viper.GetString("recipient")
	contentType := "pgWAL"

	// Initialize minio client object.
	minioClient := getS3Connection()

	// Test if bucket is there
	exists, err := minioClient.BucketExists(bucket)
	if err != nil {
		log.Fatal(err)
	}
	if exists {
		log.Debugf("Bucket already exists, we are using it: %s", bucket)
	} else {
		// Try to create bucket
		err = minioClient.MakeBucket(bucket, location)
		if err != nil {
			log.Fatal(err)
		}
		log.Infof("Bucket %s created.", bucket)
	}

	// This command is used to take the wal and compress it
	compressCmd := exec.Command(cmdZstd, "--stdout", walSource)
	// attach pipe to the command
	compressStdout, err := compressCmd.StdoutPipe()
	if err != nil {
		log.Fatal("Can not attach pipe to backup process, ", err)
	}
	s3Input := compressStdout
	// Watch output on stderror
	compressStderror, err := compressCmd.StderrPipe()
	ec.Check(err)
	go util.WatchOutput(compressStderror, log.Info)

	// Variables need for encryption
	var gpgCmd *exec.Cmd
	if encrypt {
		log.Debug("Encrypt data, encrypt: ", encrypt)
		// Encrypt the compressed data
		gpgCmd = exec.Command(cmdGpg, "--encrypt", "-o", "-", "--recipient", recipient)
		// Set the encryption output as input for S3
		s3Input, err = gpgCmd.StdoutPipe()
		if err != nil {
			log.Fatal("Can not attach pipe to gpg process, ", err)
		}
		// Attach output of WAL to stdin
		gpgCmd.Stdin = compressStdout
		// Watch output on stderror
		gpgStderror, err := gpgCmd.StderrPipe()
		ec.Check(err)
		go util.WatchOutput(gpgStderror, log.Warn)

		// Start encryption
		if err := gpgCmd.Start(); err != nil {
			log.Fatal("gpg failed on startup, ", err)
		}
		log.Debug("gpg started")
		contentType = "pgp"
	}

	// Start backup and compression
	if err := compressCmd.Start(); err != nil {
		log.Fatal("zstd failed on startup, ", err)
	}
	log.Debug("Compression started")

	// Write data to S3
	n, err := minioClient.PutObject(bucket, walTarget, s3Input, contentType)
	if err != nil {
		log.Fatal(err)
		return
	}
	log.Infof("Written %d bytes to %s in bucket %s.", n, walTarget, bucket)

	// If there is still data in the output pipe it can be lost!
	err = compressCmd.Wait()
	if err != nil {
		log.Fatal("compression failed after startup, ", err)
	} else {
		log.Debug("Compression done")
	}

	if encrypt {
		err = gpgCmd.Wait()
		if err != nil {
			log.Fatal("gpg failed after startup, ", err)
		} else {
			log.Debug("Encryption done")
		}
	}
	return err
}

func init() {
	RootCmd.AddCommand(archiveCmd)
}
