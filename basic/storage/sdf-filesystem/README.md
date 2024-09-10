this example shows how to request a specific sdf filesystem to be mounted into your pod.

we utilise different storageClasses to represent a specific sdf filesystem. this allows us stronger control over which filesystems can be mounted on specific vclusters and thus provides protection between facilities as each vcluster can only mount predefined (and approved) filesystems.
