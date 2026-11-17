# Jobs and CronJobs (finished-pod cleanup)

A Job runs a task to completion in one or more pods, and retries the attempts that fail. A CronJob
creates a Job on a schedule. Use them for batch work: processing a dataset, a nightly report, a
copy to another system. The host cluster deletes every finished pod within minutes, together with
its logs, so a Job must keep its results and logs somewhere other than its pods. Jobs and CronJobs
need no platform switch. The example claim uses `wekafs--sdf-k8s01`, which is on every vcluster's
StorageClass allowlist by default; a claim in a class not on your allowlist never binds. See
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How finished pods are deleted

1. Your Jobs and CronJobs stay in your vcluster. Only the pods they create sync to the host
   cluster, into `vcluster--<name>`.
2. Every 15 minutes, a Kyverno cleanup on the host deletes every pod in phase `Succeeded` or
   `Failed` that was created more than 10 minutes earlier. It covers the host namespace of every
   vcluster.
3. When the host copy of a pod is deleted, the vcluster deletes the pod in your vcluster too, at
   once. Its logs and status go with it.

The cleanup keeps finished pods from piling up on the host, which holds a copy of every pod of
every vcluster. It looks only at a pod's phase and age: your Jobs, with their history limits and
`ttlSecondsAfterFinished`, stay in your vcluster, where the host does not see them.

Age counts from the pod's creation, not from when it finished:

- A pod that finishes within 10 minutes of its creation is deleted 10 to 25 minutes after it was
  created.
- A pod that runs longer is deleted at the first cleanup after it finishes: within 15 minutes, and
  possibly seconds after it ends.

The cleanup acts only on finished pods, and treats them all the same: a Job's, a CronJob's, a bare
pod's, and an evicted pod, which is `Failed` and which its Deployment or StatefulSet replaces (see
[Disruptions](../scheduling/disruptions/README.md)). It leaves running and `Pending` pods alone.
[Platform policies](../platform-policies/README.md) lists every rule the host applies to your
objects.

The host's other cleanups do not reach your objects. Its cleanup of empty ReplicaSets acts only on
ReplicaSets on the host; your Deployments and their ReplicaSets stay in your vcluster, so
`revisionHistoryLimit` and `kubectl rollout undo` work as usual. Its kube-cleanup-operator deletes
only Jobs on the host and the pods they own; your Jobs stay in your vcluster, and the host copies
of your pods belong to your vcluster, not to a Job. The Jobs a CronJob created are kept as its
history limits say.

## What is left after the cleanup

| What | After the pod is deleted |
|---|---|
| The pod in `kubectl get pods` and `kubectl describe pod` | Gone |
| The pod's logs (`kubectl logs`) | Gone |
| The pod's status: exit code, `OOMKilled`, termination message | Gone |
| Files in an `emptyDir` or in the container's own filesystem | Gone |
| The Job, with its `Complete` or `Failed` condition and its counts of succeeded and failed pods | Kept, until you delete it or its `ttlSecondsAfterFinished` does |
| The Jobs a CronJob created | Kept, as many as its history limits allow |
| Events about the pod (`kubectl get events`) | Kept for about an hour, as in any cluster |
| Files the pod wrote to a PersistentVolumeClaim, including an S3DF filesystem claim | Kept |

## Keeping results and logs

- Write results to a claim: a [Weka claim](../storage/weka/README.md) of your own, as in the
  examples, or an [S3DF filesystem claim](../storage/sdf-filesystem/README.md) when the results
  belong on an S3DF share. A service outside the cluster works too.
- Write the log of each attempt to the claim, next to the results. The examples write
  `<pod>.log` into a directory named after the Job, so the logs of failed attempts are kept as
  well.
- Print a short summary to standard output, and follow it while the Job runs:
  `kubectl logs -f job/<job>`.
- A CronJob can copy results to an S3DF share: mount an S3DF filesystem claim next to the results
  claim, and copy the files in the CronJob's command.

For container logs and events in general, see
[Container logs and Kubernetes events](../logging/README.md).

## Job settings

| Field | In the examples | What it is for |
|---|---|---|
| `restartPolicy` | `Never` | A failed container ends its pod, and the Job starts a new pod for the next attempt, so each attempt has a pod and a log file of its own. With `OnFailure` the container restarts inside the same pod, so each attempt overwrites the log file of the one before, and the Job stops the pod when it reaches the backoff limit |
| `backoffLimit` | `2` in the Job, `1` in the CronJob | How many failed attempts the Job retries before it fails. The default, `6`, with waits that double from 10 seconds, retries for more than ten minutes, so the cleanup can delete the first failed pods before the Job fails |
| `activeDeadlineSeconds` | `3600` | Fails the Job, and stops its running pod, after an hour, so a stuck run does not hold its resources forever |
| `ttlSecondsAfterFinished` | `86400`, in the Job only | Deletes the Job a day after it finishes. Without it, finished Jobs stay until you delete them. A CronJob's history limits already remove its old Jobs |

## CronJob settings

| Field | In the example | What it is for |
|---|---|---|
| `schedule` | `"15 4 * * *"` | 04:15 every day, in cron format |
| `timeZone` | `America/Los_Angeles` | The time zone of `schedule`. Without it, the schedule follows the time zone of the vcluster's controller manager |
| `concurrencyPolicy` | `Forbid` | Skips a run while the previous one still runs. The default, `Allow`, runs them side by side, writing to the same claim |
| `startingDeadlineSeconds` | `600` | A run that cannot start within 10 minutes of its time, for example because the previous run is still going, is skipped, not started later |
| `successfulJobsHistoryLimit`, `failedJobsHistoryLimit` | `3` and `3` | How many finished Jobs to keep, with their status. They keep Jobs, not pods: the pods are deleted anyway. The defaults are `3` and `1` |

## Examples

| File | What it shows |
|---|---|
| [`pvc.yaml`](pvc.yaml) | A 1Gi `ReadWriteMany` Weka claim for results and logs |
| [`job.yaml`](job.yaml) | A one-off Job: two retries, a one-hour deadline, the Job deleted a day after it ends; its result and the log of each attempt on the claim |
| [`cronjob.yaml`](cronjob.yaml) | A nightly CronJob: a fixed time zone, no overlapping runs, history limits; each run's output and log on the claim, and runs older than 30 days deleted |
| [`pod-results-reader.yaml`](pod-results-reader.yaml) | A pod that mounts the claim read-only for an hour, to read results and logs after the Jobs' pods are gone |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how to
create one. The Job, the CronJob and the reader all use the claim from `pvc.yaml`. The containers
run as user 1000: the Weka class creates the volume's directory writable by everyone, so a
non-root container can write to it.

```bash
kubectl apply -n my-namespace -f pvc.yaml -f job.yaml
kubectl wait -n my-namespace --for=condition=complete job/my-app-batch --timeout=5m
kubectl logs -n my-namespace job/my-app-batch   # result: 5050, until the cleanup deletes the pod
```

## Mistakes that lose results or logs

| Mistake | Result |
|---|---|
| Reading `kubectl logs` or `kubectl describe pod` later | The pod is gone 10 to 25 minutes after its creation, or within 15 minutes of finishing for a longer run. Follow the log while the Job runs, and write it to a claim |
| Results only in the container's filesystem or in an `emptyDir` | Deleted with the pod |
| Waiting to inspect a failed pod | It is deleted like any other finished pod. To look inside a failing container, end its command with `\|\| sleep 3600` while you debug: the pod stays `Running`, the cleanup leaves it alone, and you can `kubectl exec` into it |
| The default `backoffLimit` for a Job that fails quickly | The retries take more than ten minutes, so the cleanup can delete the first failed pods, and their logs, before the Job fails |
| A bare pod for a one-off task | Once the cleanup deletes it, nothing records whether it succeeded. A Job keeps its status |
| Expecting `successfulJobsHistoryLimit` or `failedJobsHistoryLimit` to keep pods | They keep the Job objects only |
| Applying a Job manifest again to run the Job again | While the Job exists, nothing runs: `kubectl apply` reports it `unchanged`, and refuses a changed pod template, because a Job's template cannot change. Delete the Job first. Once the Job is gone, deleted by you or by `ttlSecondsAfterFinished`, applying the manifest runs it again |
| No `concurrencyPolicy: Forbid` on a CronJob whose run can outlast its interval | Runs overlap and write to the same files |
| Keeping the output of every run | A Weka claim's size is a hard quota, and writes fail once it is full. Delete old runs, as `cronjob.yaml` does |

## Checking

```bash
# The Job keeps its status after its pods are gone: Complete, or Failed with a reason
# such as BackoffLimitExceeded or DeadlineExceeded.
kubectl get job -n my-namespace my-app-batch
kubectl describe job -n my-namespace my-app-batch

# The Job's pods, while they exist, with their creation times.
kubectl get pods -n my-namespace -l batch.kubernetes.io/job-name=my-app-batch \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,CREATED:.metadata.creationTimestamp

# Run the CronJob's Job now, without waiting for its schedule.
kubectl apply -n my-namespace -f pvc.yaml -f cronjob.yaml
kubectl create job -n my-namespace my-app-nightly-manual --from=cronjob/my-app-nightly
kubectl get cronjob,job -n my-namespace

# Results and logs on the claim, after the pods are gone.
kubectl apply -n my-namespace -f pod-results-reader.yaml
kubectl exec -n my-namespace my-app-results-reader -- ls -lR /results
kubectl exec -n my-namespace my-app-results-reader -- cat /results/my-app-batch/result.txt
kubectl delete -n my-namespace pod my-app-results-reader
```

Upstream reference: [Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/) and
[CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) in the Kubernetes
documentation. The upstream Job guide says finished pods are usually kept so you can read their
logs; on this platform they are not.
