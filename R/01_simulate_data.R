# =============================================================================
# 01_simulate_data.R
# Synthetic subscription business (telecom-style): 6,000 customers observed
# for up to 36 months. Monthly churn hazard depends on contract type, price,
# support experience and engagement, so both "who churns" and "when" can be
# analysed.
# =============================================================================

set.seed(31)
RNGkind(sample.kind = "Rejection")
n <- 6000

contract <- factor(sample(c("Month-to-month", "One year", "Two year"), n, TRUE, c(0.55, 0.25, 0.20)),
                   levels = c("Month-to-month", "One year", "Two year"))
internet <- factor(sample(c("DSL", "Fiber", "None"), n, TRUE, c(0.35, 0.45, 0.20)))
tech_support <- rbinom(n, 1, ifelse(internet == "None", 0, 0.35))
auto_pay <- rbinom(n, 1, 0.45)
senior <- rbinom(n, 1, 0.16)
monthly_charges <- round(20 + 25 * (internet == "DSL") + 50 * (internet == "Fiber") +
                         8 * tech_support + rnorm(n, 0, 6), 2)
support_tickets_6m <- rpois(n, 0.6 + 0.8 * (internet == "Fiber") * (1 - tech_support))

# Monthly churn hazard (log scale)
lh <- log(0.012) + 1.30 * (contract == "Month-to-month") - 0.70 * (contract == "Two year") +
      0.45 * (internet == "Fiber") - 0.55 * tech_support - 0.40 * auto_pay +
      0.25 * senior + 0.012 * (monthly_charges - 65) + 0.22 * support_tickets_6m
months_to_churn <- rexp(n, rate = exp(lh))
follow_up <- sample(1:36, n, TRUE)                                   # months since sign-up
tenure_months <- pmin(ceiling(months_to_churn), follow_up)
churned <- as.integer(months_to_churn <= follow_up)

customers <- data.frame(customer_id = sprintf("C%05d", 1:n), contract, internet,
                        tech_support, auto_pay, senior, monthly_charges, support_tickets_6m,
                        tenure_months, churned)
dir.create("data", showWarnings = FALSE)
write.csv(customers, "data/customers.csv", row.names = FALSE)
cat(sprintf("Saved data/customers.csv: %d customers, churn rate %.1f%%\n", n, 100 * mean(churned)))
