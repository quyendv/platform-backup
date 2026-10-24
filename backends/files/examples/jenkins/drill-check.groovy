// Restore drill check. drill.sh copies this into init.groovy.d of a restored,
// network-less Jenkins; it is never part of a backup.
//
// It stops the instance from running anything, then prints one line of counts
// and never a value:
//
//   DRILL jobs=<n> folders=<n> nodes=<n> credentials=<n> verifiable=<n> decrypted=<n>
//
// "credentials" counts every credential; "verifiable" those holding a value
// this script can read back: a Secret or SecretBytes, or a String from a getter
// named like a key, password, secret, token or passphrase (an SSH private key
// is returned as a String, a missing passphrase as null); "decrypted" those
// whose every such value decrypted with the restored key. With a wrong key
// Jenkins does not fail: it keeps the ciphertext as if it were the plain value,
// so a value that still looks like "{AQAA...}" is what an undecrypted secret
// looks like. Each credential it cannot verify is named by type on a
// DRILL-UNVERIFIED line, never by value.

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

def secretish = ~/(?i)^get.*(key|password|secret|token|passphrase).*/

def secretValues = { cred ->
  def values = []
  cred.class.methods.findAll { it.parameterCount == 0 && it.name.startsWith('get') }.each { m ->
    def v
    try { v = m.invoke(cred) } catch (Throwable t) { return }
    if (v == null) return
    if (v instanceof Secret) {
      values << v.plainText
    } else if (v.class.name == 'com.cloudbees.plugins.credentials.SecretBytes') {
      values << new String(v.plainData, 'UTF-8')
    } else if (m.name ==~ secretish && v instanceof String) {
      values << v
    } else if (m.name ==~ secretish && v instanceof Collection) {
      values.addAll(v.findAll { it instanceof String })
    }
  }
  values.findAll { it != null && !it.isEmpty() }
}

// Every credentials store owned by Jenkins itself or by a folder, each once.
def contexts = [jenkins] + jenkins.getAllItems(com.cloudbees.hudson.plugins.folder.AbstractFolder)
def creds = []
contexts.each { ctx ->
  CredentialsProvider.lookupStores(ctx).findAll { it.context == ctx }.each { store ->
    store.domains.each { domain -> creds.addAll(store.getCredentials(domain)) }
  }
}

def verifiable = 0
def decrypted = 0
creds.each { c ->
  def values = secretValues(c)
  if (values.isEmpty()) {
    println("DRILL-UNVERIFIED ${c.class.name}")
    return
  }
  verifiable++
  // Long ciphertexts (an SSH private key) are stored with line breaks.
  if (!values.any { it.replaceAll(/\s/, '') ==~ encrypted }) decrypted++
}

def jobs = jenkins.getAllItems(Job).size()
def folders = contexts.size() - 1
def nodes = jenkins.nodes.size()
println("DRILL jobs=${jobs} folders=${folders} nodes=${nodes} credentials=${creds.size()} verifiable=${verifiable} decrypted=${decrypted}")
