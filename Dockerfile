# Copyright Istio Authors
# Licensed under the Apache License, Version 2.0 (the "License")

FROM gcr.io/distroless/cc:nonroot

ARG NAME
ENV NAME=${NAME}

COPY ./build/${NAME}_linux_amd64/${NAME}.stripped /app/auth_server
USER nonroot:nonroot
ENTRYPOINT ["/app/auth_server"]
