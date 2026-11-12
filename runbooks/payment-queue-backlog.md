# ShopPaymentQueueBacklog

The payment queue has held more than 100 payments for 5 minutes.

## 1. Is the gateway retrying?

A backlog usually means the payment gateway is slow and the workers are retrying.

```promql
sum(rate(shop_payment_gateway_retries_total[5m]))
```

More than about 0.5/s: the gateway is degraded. Check its status page before
touching the workers.

## 2. Restart the workers

Only if retries are normal:

```sh
podman compose restart shop
```
