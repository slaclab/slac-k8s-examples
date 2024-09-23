
this is an example of making use of a layer 4 network proxy (socat) and overriding a pods resolve (via /etc/hosts) so that we can force traffic /out/ of kubernetes via a specific ip address. specifically, we make use of multus to pin this socat proxy pod to the relevant subnet and force the traffic through this interface. since socat is literally just conducting a reconnect to the target destination, and since the application pod has its dns overridden to point (to the service) of this pod, the pod is non-the-wiser. you could argue that this is a man-in-the-middlel attack, but since the application pod is in control of what gets redirected, its no worse than a simple proxy.

todo:
- modify the multus tables to ensure all traffic on the socat proxy container goes through the multus interface and not the internal one.
