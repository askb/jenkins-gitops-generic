// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 The Linux Foundation
// Print what JCasC actually configured, one "kind=name" per line.
// Run through /scriptText by scripts/lib.sh live_objects.
import jenkins.model.Jenkins

def j = Jenkins.get()
j.clouds.each { println "cloud=${it.name}" }
com.cloudbees.plugins.credentials.SystemCredentialsProvider.instance.credentials.each {
  println "cred=${it.id}"
}
org.jenkinsci.plugins.configfiles.GlobalConfigFiles.get().configs.each { println "file=${it.id}" }
if (j.getPlugin('gerrit-trigger') != null) {
  com.sonyericsson.hudson.plugins.gerrit.trigger.PluginImpl.instance.serverNames.each {
    println "gerrit=${it}"
  }
}
