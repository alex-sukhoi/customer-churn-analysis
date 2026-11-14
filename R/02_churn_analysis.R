# =============================================================================
# 02_churn_analysis.R
#   1. Churn profile by segment
#   2. Who churns: logistic regression (odds ratios), 70/30 train-test split,
#      AUC, calibration by risk decile, lift
#   3. When they churn: Kaplan-Meier retention by contract, Cox model
#   4. Action: risk segments and monthly revenue at risk
# =============================================================================

suppressPackageStartupMessages({ library(survival); library(ggplot2) })
dir.create("results", showWarnings = FALSE); dir.create("figures", showWarnings = FALSE)
d <- read.csv("data/customers.csv", stringsAsFactors = TRUE)
d$contract <- factor(d$contract, levels = c("Month-to-month", "One year", "Two year"))
d$internet <- factor(d$internet, levels = c("DSL", "Fiber", "None"))
set.seed(31)

# --- 1. Churn profile ----------------------------------------------------------
seg <- function(v) {
  g <- split(d$churned, as.character(d[[v]]))
  data.frame(variable = v, level = names(g), customers = sapply(g, length),
             churn_rate_pct = round(100 * sapply(g, mean), 1), row.names = NULL)
}
profile <- do.call(rbind, lapply(c("contract", "internet", "tech_support", "auto_pay", "senior"), seg))
write.csv(profile, "results/01_churn_by_segment.csv", row.names = FALSE)

# --- 2. Logistic regression ------------------------------------------------------
idx <- sample(nrow(d), round(0.7 * nrow(d)))
train <- d[idx, ]; test <- d[-idx, ]
# tenure is left out on purpose: it is partly an outcome (churners have short
# tenure by definition) and would leak information. Timing is modelled in step 3.
f <- churned ~ contract + internet + tech_support + auto_pay + senior + monthly_charges +
  support_tickets_6m
logit <- glm(f, data = train, family = binomial)
ci <- suppressMessages(confint.default(logit))
or <- data.frame(term = names(coef(logit)), odds_ratio = round(exp(coef(logit)), 3),
                 ci_low = round(exp(ci[, 1]), 3), ci_high = round(exp(ci[, 2]), 3),
                 p = signif(summary(logit)$coefficients[, 4], 3), row.names = NULL)
write.csv(or[-1, ], "results/02_logistic_odds_ratios.csv", row.names = FALSE)

auc <- function(y, p) {           # Mann-Whitney formulation of the ROC AUC
  r <- rank(p); n1 <- sum(y == 1); n0 <- sum(y == 0)
  (sum(r[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
test$p <- predict(logit, test, type = "response")
train$p <- predict(logit, train, type = "response")
test$decile <- cut(rank(-test$p, ties.method = "first"), 10, labels = 1:10)
calib <- aggregate(cbind(predicted = p, observed = churned) ~ decile, data = test, FUN = mean)
calib$lift <- round(calib$observed / mean(test$churned), 2)
calib[, 2:3] <- round(calib[, 2:3], 3)
write.csv(calib, "results/03_calibration_and_lift_by_decile.csv", row.names = FALSE)
perf <- data.frame(metric = c("AUC train", "AUC test", "Brier score test", "Top-decile lift (test)",
                              "Share of churners in top 30% (test)"),
                   value = round(c(auc(train$churned, train$p), auc(test$churned, test$p),
                                   mean((test$p - test$churned)^2), calib$lift[1],
                                   sum(test$churned[as.integer(test$decile) <= 3]) / sum(test$churned)), 3))
write.csv(perf, "results/04_model_performance.csv", row.names = FALSE)

# --- 3. Survival view --------------------------------------------------------------
S <- with(d, Surv(tenure_months, churned))
km <- survfit(S ~ contract, data = d)
ret12 <- summary(km, times = c(12, 24, 36))
retention <- data.frame(contract = sub("contract=", "", ret12$strata), month = ret12$time,
                        retained_pct = round(100 * ret12$surv, 1))
write.csv(retention, "results/05_retention_by_contract.csv", row.names = FALSE)
cox <- coxph(S ~ contract + internet + tech_support + auto_pay + senior + monthly_charges +
               support_tickets_6m, data = d)
sc <- summary(cox)
hr <- data.frame(term = rownames(sc$conf.int), HR = round(sc$conf.int[, 1], 2),
                 ci_low = round(sc$conf.int[, 3], 2), ci_high = round(sc$conf.int[, 4], 2),
                 p = signif(sc$coefficients[, 5], 3), row.names = NULL)
write.csv(hr, "results/06_cox_hazard_ratios.csv", row.names = FALSE)

kmdf <- data.frame(time = c(0, km$time), surv = c(1, km$surv),
                   contract = c(NA, rep(sub("contract=", "", names(km$strata)), km$strata)))
kmdf$contract[1] <- NA
starts <- data.frame(time = 0, surv = 1, contract = levels(d$contract))
kmdf <- rbind(starts, kmdf[-1, ])
g1 <- ggplot(kmdf, aes(time, surv, colour = contract)) + geom_step(linewidth = 1) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_x_continuous(breaks = seq(0, 36, 6)) +
  scale_colour_manual(values = c("#c53030", "#dd6b20", "#2b6cb0")) +
  labs(title = "Customer retention by contract type (Kaplan-Meier)",
       subtitle = sprintf("Adjusted Cox HR: two-year contracts churn at %.0f%% of the month-to-month rate",
                          100 * sc$conf.int["contractTwo year", 1]),
       x = "Months since sign-up", y = "Still a customer", colour = NULL) +
  theme_minimal(base_size = 12) + theme(legend.position = "top")
ggsave("figures/retention_by_contract.png", g1, width = 7.5, height = 4.5, dpi = 110)

# --- 4. Risk segments and revenue at risk -------------------------------------------
d$p_churn <- predict(logit, d, type = "response")
d$risk <- cut(d$p_churn, c(0, 0.15, 0.35, 1), labels = c("Low", "Medium", "High"))
risk <- aggregate(cbind(customers = 1, churned, monthly_charges) ~ risk, data = d, FUN = sum)
risk$churn_rate_pct <- round(100 * risk$churned / risk$customers, 1)
risk$expected_lost_revenue_month <- round(tapply(d$p_churn * d$monthly_charges, d$risk, sum))
risk$share_of_revenue_at_risk_pct <- round(100 * risk$expected_lost_revenue_month /
                                             sum(risk$expected_lost_revenue_month), 1)
risk$monthly_charges <- NULL
write.csv(risk, "results/07_risk_segments.csv", row.names = FALSE)

g2 <- ggplot(calib, aes(as.integer(decile), observed)) +
  geom_col(fill = "#2b6cb0", width = 0.7) +
  geom_point(aes(y = predicted), colour = "#dd6b20", size = 3) +
  geom_hline(yintercept = mean(test$churned), linetype = "dashed", colour = "grey40") +
  scale_x_continuous(breaks = 1:10) + scale_y_continuous(labels = scales::percent) +
  labs(title = "Hold-out test set: churn rate by predicted-risk decile",
       subtitle = sprintf("Bars = observed, dots = predicted; AUC = %.2f; top decile lift = %.1fx",
                          perf$value[2], perf$value[4]),
       x = "Risk decile (1 = highest predicted risk)", y = "Churn rate") +
  theme_minimal(base_size = 12)
ggsave("figures/lift_by_decile.png", g2, width = 7.5, height = 4.5, dpi = 110)

print(profile, row.names = FALSE); print(or[-1, ], row.names = FALSE); print(perf, row.names = FALSE)
print(retention, row.names = FALSE); print(hr, row.names = FALSE); print(risk, row.names = FALSE)
