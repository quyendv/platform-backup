// Restore drill check. drill.sh copies this into init.groovy.d of a restored,
// network-less Jenkins; it is never part of a backup.
//
// It stops the instance from running anything, then prints one line of counts
// and never a value:
//
//   DRILL jobs=<n> folders=<n> nodes=<n> credentials=<n> decrypted=<n>
//
// "credentials" counts the credentials that hold a Secret or SecretBytes;
// "decrypted" those whose every secret decrypted with the restored key. With a
// wrong key Jenkins does not fail: Secret.fromString keeps the ciphertext as
// if it were the plain value, so a value that still looks like "{AQAA...}" is
// what an undecrypted secret looks like.

import com.cloudbees.plugins.credentials.CredentialsProvider
import hudson.model.Job
import hudson.util.Secret
import jenkins.model.Jenkins

def jenkins = Jenkins.get()

// Nothing restored may run: no executors on the built-in node, and quiet-down
// for anything already queued. drill.sh also starts it with no network.
try {
  jenkins.setNumExecutors(0)
  jenkins.doQuietDown()
} catch (Throwable t) {
  println("DRILL-WARN could not quiet down: ${t.class.simpleName}")
}

def encrypted = ~/^\{[A-Za-z0-9+\/=]+\}$/

def secretValues = { cred ->
  def values = []
  cred.class.methods.findAll { it.parameterCount == 0 && it.name.startsWith('get') }.each { m ->
    if (Secret.isAssignableFrom(m.returnType)) {
      def s = m.invoke(cred)
      if (s != null) values << s.plainText
    } else if (m.returnType.name == 'com.cloudbees.plugins.credentials.SecretBytes') {
      def s = m.invoke(cred)
      if (s != null) values << new String(s.plainData, 'UTF-8')
    }
  }
  values
}

// Every credentials store owned by Jenkins itself or by a folder, each once.
def contexts = [jenkins] + jenkins.getAllItems(com.cloudbees.hudson.plugins.folder.AbstractFolder)
def creds = []
contexts.each { ctx ->
  CredentialsProvider.lookupStores(ctx).findAll { it.context == ctx }.each { store ->
    store.domains.each { domain -> creds.addAll(store.getCredentials(domain)) }
  }
}

def checkable = 0
def decrypted = 0
creds.each { c ->
  def values = secretValues(c)
  if (values.isEmpty()) return
  checkable++
  if (!values.any { it ==~ encrypted }) decrypted++
}

def jobs = jenkins.getAllItems(Job).size()
def folders = contexts.size() - 1
def nodes = jenkins.nodes.size()
println("DRILL jobs=${jobs} folders=${folders} nodes=${nodes} credentials=${checkable} decrypted=${decrypted}")
