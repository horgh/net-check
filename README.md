net-check is a program which monitors for connection loss, and if it detects a
loss, takes action to recover the connection.

My use case is for systems on unstable connections to repair themselves.
Specifically, I have a few Raspberry Pis acting as small servers that I want to
self heal.


# How it works
net-check runs as a daemon (though does not currently background, so it needs
to be run inside something like GNU Screen or in another manner that will let
it run without being terminated). It repeatedly (with a delay) makes HTTP
requests to a configured host and examines the result. If the result does not
contain the string you configure too many times in a row, net-check takes a
recovery action. You can define the recovery action.

By default it makes one HTTP request every 10 minutes. If the request fails or
does not contain the configured string 6 times in a row (so 60 minutes in
total), then it runs the recovery action. You can configure each of these
parameters.
