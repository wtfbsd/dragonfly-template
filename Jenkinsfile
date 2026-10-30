// Jenkinsfile — CI for the DragonFly template.
//
// Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
//
// This file is generic: no organisation names, no host names, no
// credentials by value. Everything a site needs is a parameter or an
// environment variable:
//
//   WTFBSD_VM_PROVIDER      the VM provider (default below); a site with
//                           its own hypervisor sets WTFBSD_VM_PROVIDER_PATH
//                           to a provider script outside this repository
//   BUILD_VM_IMAGE          the disk image the build VM boots
//
// The product configuration is a stashed file parameter: the File
// Parameter plugin has to be installed on the controller, because a file
// parameter does not land in the workspace of a pipeline on its own
// (JENKINS-27413). The pipeline stashes it and unstashes it again, and
// the build then uses the copy of the file under the name product.conf.
//
// The first-boot user of the image needs a way in. The pipeline takes
// two file credentials of the controller for it:
//
//   wtfbsd-ci-ssh-pubkey     the authorized_keys line of the CI user
//   wtfbsd-ci-password-hash  the crypt(3) hash of the password of the
//                            CI user (never a plain text password)
//
// Both are named by their id only: no key and no hash is ever written
// into this repository, and the two files are removed from the guest
// right after the build.
//
// DragonFly cannot be cross-built: the build has to run on DragonFly
// itself, so the build VM image is a DragonFly system with an unmodified
// source tree in /usr/src. The build runs in a throwaway build VM by
// default: a world build takes hours and a lot of disk. With
// BUILD_ON_AGENT the build runs on the agent itself, which is only
// sensible for a DragonFly machine that already holds an unmodified
// DragonFly source tree.
//
// The names of the VMs carry the name of the job and the number of the
// build, so that two builds of the same job never fight for the same
// VM. Every VM that is created is written into the file .vm/vmlist
// BEFORE it is created, and the post block destroys every name in that
// list: a VM that was created and not destroyed is destroyed anyway.
// The build VM is destroyed at the end of the build stage as well, so
// that it does not hold memory while the boot test runs.
//
// UNVERIFIED: this file was not run on a Jenkins controller here (no
// Jenkins in the environment of the author). The shell of every stage is
// checked by the test suite of this repository.

pipeline {
	agent { label "${params.AGENT_LABEL}" }

	parameters {
		string(
			name: 'AGENT_LABEL',
			defaultValue: 'bsd-builder',
			description: 'Label of the Jenkins agent that runs the pipeline')
		choice(
			name: 'PROFILE',
			choices: ['desktop', 'appliance', 'both'],
			description: 'appliance = headless, serial console + sshd; desktop = X11 Xfce + LightDM; both = one media of each')
		booleanParam(
			name: 'BUILD_ON_AGENT',
			defaultValue: false,
			description: 'Build on the agent instead of in a build VM')
		stashedFile(
			name: 'PRODUCT_CONF',
			description: 'product.conf produced by the answers script (File Parameter plugin: the pipeline stashes and unstashes the file)')
		string(
			name: 'VM_PROVIDER',
			defaultValue: 'bhyve',
			description: 'VM provider used for the build VM and the boot test')
		string(
			name: 'BUILD_VM_NAME',
			defaultValue: 'wtfbsd-build',
			description: 'Name of the build VM (the job name and the build number are added)')
		string(
			name: 'BUILD_VM_IMAGE',
			defaultValue: '',
			description: 'DragonFly disk image the build VM boots; required when BUILD_ON_AGENT is false')
		string(
			name: 'BUILD_VM_WORKDIR',
			defaultValue: 'wtfbsd-dragonfly-template',
			description: 'Directory of this repository inside the build VM')
	}

	environment {
		WTFBSD_VM_PROVIDER = "${params.VM_PROVIDER}"
	}

	stages {
		stage('Validate params') {
			steps {
				script {
					// The File Parameter plugin stashes the uploaded file
					// under the name of the parameter; it does not land in
					// the workspace of the pipeline on its own
					// (JENKINS-27413). Unstashing it puts it there.
					unstash 'PRODUCT_CONF'
				}
				sh '''
					set -eu
					case "$PROFILE" in
					desktop | appliance | both) ;;
					*) echo "PROFILE must be desktop, appliance or both" >&2; exit 1 ;;
					esac
					# every free-text parameter is checked against
					# ^[A-Za-z0-9._/-]+$ before anything is built
					sh ci/validate-params.sh
					# the unstashed file is in the workspace under the
					# name of the parameter
					[ -f PRODUCT_CONF ] || { echo "no PRODUCT_CONF in the workspace" >&2; exit 1; }
					# the file parameter lands in the workspace under the
					# name of the parameter; the build of every stage uses
					# the copy of the file under the name product.conf
					cp PRODUCT_CONF product.conf
					# the list of the VMs of this build starts empty: the
					# post block destroys every name in it
					mkdir -p .vm
					: > .vm/vmlist
					slug=$(sed -n 's/^DISTRO_SLUG=//p' product.conf | head -1 | tr -cd 'A-Za-z0-9_-')
					arch=$(sed -n 's/^DISTRO_ARCH=//p' product.conf | head -1 | tr -cd 'A-Za-z0-9_')
					[ -n "$slug" ] || { echo "no DISTRO_SLUG in product.conf" >&2; exit 1; }
					[ -n "$arch" ] || arch=amd64
					printf '%s\n' "$slug" > .distro_slug
					printf '%s\n' "$arch" > .distro_arch
					# the dry run validates the product configuration and
					# prints the whole plan without touching anything
					sh build.sh -c product.conf -n
				'''
			}
		}

		stage('Test') {
			steps {
				// the suite of the template runs on the agent: it needs
				// no root, no network and no VM
				sh 'sh tests/run-tests.sh'
			}
		}

		stage('Build') {
			steps {
				script {
					// The first-boot user of the image: the key of the CI
					// and the hash of its password. Both are file
					// credentials of the controller, and they are named
					// by their id only: no key and no hash is ever
					// written into this repository.
					withCredentials([
						file(credentialsId: 'wtfbsd-ci-ssh-pubkey', variable: 'CI_SSH_PUBKEY'),
						file(credentialsId: 'wtfbsd-ci-password-hash', variable: 'CI_PASSWORD_HASH')
					]) {
						if (params.BUILD_ON_AGENT) {
							sh '''
								set -eu
								sh build.sh -c product.conf -p "$PROFILE" \
									-u ciuser -k "$CI_SSH_PUBKEY" -P "$CI_PASSWORD_HASH"
							'''
						} else {
							sh '''
								set -eu
								# the name of the build VM carries the name of the
								# job and the number of the build
								vm=$(printf '%s' "$BUILD_VM_NAME-$JOB_BASE_NAME-$BUILD_NUMBER" | tr -c 'A-Za-z0-9._-' '-')
								[ "${#vm}" -le 64 ] || vm=$(printf '%s' "$vm" | cut -c1-64)
								printf '%s\n' "$vm" > .build_vm_name
								# the slot of the build VM: the boot-test VMs
								# of the same job have another one
								WTFBSD_VM_SLOT=0 sh ci/vm.sh create "$vm" "$BUILD_VM_IMAGE"
							'''
							sh '''
								set -eu
								addr=""
								i=0
								while [ "$i" -lt 60 ]; do
									if addr=$(sh ci/vm.sh addr "$(cat .build_vm_name)" 2>/dev/null) && [ -n "$addr" ]; then
										break
									fi
									i=$((i + 1))
									sleep 5
								done
								[ -n "$addr" ] || { echo "the build VM never got an address" >&2; exit 1; }
								printf '%s\n' "$addr" > .build_vm_addr
							'''
							sh '''
								set -eu
								addr=$(cat .build_vm_addr)
								# the guest must accept the CI key; the site
								# provisions that in its own VM image
								mkdir -p .ssh
								# the known hosts file of the workspace starts
								# empty for every build: a host that changed its
								# key is never accepted silently
								rm -f .ssh/known_hosts
								touch .ssh/known_hosts
								# the options are words of their own on purpose:
								# ssh(1) and scp(1) take them one by one
								SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$PWD/.ssh/known_hosts"
								tar -cf - --exclude=.git . | ssh $SSH_OPTS "$addr" "mkdir -p '$BUILD_VM_WORKDIR' && tar -xf - -C '$BUILD_VM_WORKDIR'"
								# the product configuration belongs to the build
								# directory of the guest
								scp $SSH_OPTS product.conf "$addr:$BUILD_VM_WORKDIR/product.conf"
								# the key of the CI and the hash of the password
								# of the first-boot user travel with it
								scp $SSH_OPTS "$CI_SSH_PUBKEY" "$addr:$BUILD_VM_WORKDIR/ci-ssh-pubkey"
								scp $SSH_OPTS "$CI_PASSWORD_HASH" "$addr:$BUILD_VM_WORKDIR/ci-password-hash"
								# the build runs as root: build.sh refuses to
								# build anything else. The account of the CI is
								# root, or it has a doas rule that needs no
								# password
								ssh $SSH_OPTS "$addr" "cd '$BUILD_VM_WORKDIR' && if [ \"\$(id -u)\" -eq 0 ]; then sh build.sh -c product.conf -p '$PROFILE' -u ciuser -k ci-ssh-pubkey -P ci-password-hash; else doas sh build.sh -c product.conf -p '$PROFILE' -u ciuser -k ci-ssh-pubkey -P ci-password-hash; fi"
								# the secrets of the build do not stay in the
								# guest
								ssh $SSH_OPTS "$addr" "rm -f '$BUILD_VM_WORKDIR/ci-ssh-pubkey' '$BUILD_VM_WORKDIR/ci-password-hash'"
								# only the artifacts come back, not the release
								# root of every profile
								profiles="$PROFILE"
								[ "$profiles" = both ] && profiles='appliance desktop'
								for p in $profiles; do
									art=$(ssh $SSH_OPTS "$addr" "cat '$BUILD_VM_WORKDIR/out/$p/ARTIFACT'")
									[ -n "$art" ] || { echo "no artifact for the $p profile" >&2; exit 1; }
									mkdir -p "out/$p"
									scp $SSH_OPTS "$addr:$art" "out/$p/"
								done
								scp $SSH_OPTS "$addr:$BUILD_VM_WORKDIR/out/SHA256" out/SHA256
							'''
							sh '''
								set -eu
								# the build VM is not needed any more; it is
								# destroyed here and again in the post block,
								# which is harmless
								sh ci/vm.sh destroy "$(cat .build_vm_name)"
							'''
						}
					}
				}
			}
		}

		stage('Boot test') {
			steps {
				script {
					def slug = sh(script: 'cat .distro_slug', returnStdout: true).trim()
					def arch = sh(script: 'cat .distro_arch', returnStdout: true).trim()
					def profiles = params.PROFILE == 'both' ? ['appliance', 'desktop'] : [params.PROFILE]
					profiles.eachWithIndex { p, i ->
						sh """
							set -eu
							art=""
							if [ -f out/${p}/ARTIFACT ]; then
								art=\$(cat out/${p}/ARTIFACT)
							else
								art=\$(ls out/${p}/${slug}-${p}-${arch}.* 2>/dev/null | head -1)
							fi
							[ -n "\$art" ] || { echo "no media for the ${p} profile" >&2; exit 1; }
							# the name of the VM carries the name of the job
							# and the number of the build
							vm=\$(printf '%s' "boot-${p}-\${env.JOB_BASE_NAME}-\${env.BUILD_NUMBER}" | tr -c 'A-Za-z0-9._-' '-')
							[ "\${#vm}" -le 64 ] || vm=\$(printf '%s' "\$vm" | cut -c1-64)
							# the name goes into the list BEFORE the VM is
							# created, so that a VM that is created and not
							# destroyed is destroyed anyway
							printf '%s\n' "\$vm" >> .vm/vmlist
							# the slot of the boot-test VM: every VM of the
							# job has a slot of its own. The slots of a
							# job are 0 (the build VM) and 1, 2 (the
							# boot-test VMs of the profile both), and the
							# provider multiplies the executor number by
							# the number of the slots
							WTFBSD_VM_SLOT=${i + 1} sh tests/boot-test.sh "\$art" ${p} "\$vm"
						"""
					}
				}
			}
		}

		stage('Archive') {
			steps {
				archiveArtifacts(
					artifacts: 'out/**/*.img,out/**/*.iso,out/SHA256',
					allowEmptyArchive: false)
			}
		}
	}

	post {
		always {
			// never leak a VM, even when the build failed: every name of
			// the list is a VM of this build
			sh '''
				set -eu
				if [ -f .build_vm_name ]; then
					sh ci/vm.sh destroy "$(cat .build_vm_name)" || true
				fi
				if [ -f .vm/vmlist ]; then
					while IFS= read -r vm; do
						[ -n "$vm" ] || continue
						sh ci/vm.sh destroy "$vm" || true
					done < .vm/vmlist
				fi
			'''
		}
	}
}
