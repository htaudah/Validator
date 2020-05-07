#!/bin/sh

# Get the certificate thumbprint from the specified URL
openssl s_client -connect $1:$2 < /dev/null 2>/dev/null | openssl x509 -fingerprint -noout -in /dev/stdin