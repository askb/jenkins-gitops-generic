# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# One controller image definition for every project. The build context is
# the repository root; PROJECT selects projects/<name>/plugins.lock.txt and
# JENKINS_VERSION comes from projects/<name>/project.yaml.
#
#   docker build -f image/Dockerfile \
#     --build-arg PROJECT=odl --build-arg JENKINS_VERSION=2.580.2 .
#
# Jobs run on agents (OpenStack VMs or pods), so no build tooling is added.

ARG JENKINS_VERSION=2.580.2
FROM jenkins/jenkins:${JENKINS_VERSION}-lts-jdk21

ARG PROJECT
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

COPY projects/${PROJECT}/plugins.lock.txt /usr/share/jenkins/ref/plugins.txt

# Every plugin, including dependencies, is pinned in the lock file;
# --latest false stops the CLI from resolving anything newer.
RUN jenkins-plugin-cli --latest false --plugin-file /usr/share/jenkins/ref/plugins.txt
