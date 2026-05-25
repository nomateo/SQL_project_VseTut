/* Часть 1. Разработка витрины данных */

WITH 
-- Шаг 1: информация об оплате каждого заказа (первый тип оплаты, промокод, рассрочка)
infocheck AS (
    SELECT order_id,
            MAX(CASE WHEN payment_sequential = 1 THEN payment_type END) AS payed_with,
            MAX(CASE WHEN payment_type = 'промокод' THEN 1 ELSE 0 END) AS promo,
            MAX(CASE WHEN payment_installments > 1 THEN 1 ELSE 0 END) AS dolg
    FROM ds_ecom.order_payments
    GROUP BY order_id
),
-- Шаг 2: стоимость каждого заказа (сумма цен товаров и доставки)
sum_cost AS (
    SELECT order_id, SUM(price + delivery_cost) AS total_cost
    FROM ds_ecom.order_items
    GROUP BY order_id
),
-- Шаг 3: исправление шкалы рейтингов и агрегация до уровня заказа
review_fixed AS (
    SELECT order_id,
            AVG(CASE WHEN review_score BETWEEN 10 AND 50 
                     THEN review_score / 10 
                     ELSE review_score END) AS review_score_fixed
    FROM ds_ecom.order_reviews
    GROUP BY order_id
),
-- Шаг 4: определение топ-3 регионов по количеству заказов
regions_top AS (
    SELECT region, COUNT(o.order_id) AS all_orders
    FROM ds_ecom.orders AS o
    JOIN ds_ecom.users AS u USING(buyer_id)
    WHERE o.order_status IN ('Доставлено', 'Отменено')
    GROUP BY region
    ORDER BY all_orders DESC
    LIMIT 3
)
-- Шаг 5: финальная агрегация по паре user_id + region
SELECT u.user_id,
    u.region,
    MIN(o.order_purchase_ts) AS first_order_ts,
    MAX(o.order_purchase_ts) AS last_order_ts,
    MAX(o.order_purchase_ts) - MIN(o.order_purchase_ts) AS lifetime,
    COUNT(o.order_id) AS total_orders,
    AVG(r.review_score_fixed) AS avg_order_rating,
    COUNT(r.review_score_fixed) AS num_orders_with_rating,
    SUM(CASE WHEN o.order_status = 'Отменено' THEN 1 ELSE 0 END) AS num_canceled_orders,
    ROUND(SUM(CASE WHEN o.order_status = 'Отменено' THEN 1 ELSE 0 END) * 1.0 / COUNT(o.order_id), 4) AS canceled_orders_ratio,
    SUM(CASE WHEN o.order_status = 'Доставлено' THEN s.total_cost END) AS total_order_costs,
    ROUND(AVG(CASE WHEN o.order_status = 'Доставлено' THEN s.total_cost END), 2) AS avg_order_cost,
    SUM(i.dolg) AS num_installment_orders,
    SUM(i.promo) AS num_orders_with_promo,
    MAX(CASE WHEN i.payed_with = 'денежный перевод' THEN 1 ELSE 0 END) AS used_money_transfer,
    MAX(i.dolg) AS used_installments,
    MAX(CASE WHEN o.order_status = 'Отменено' THEN 1 ELSE 0 END) AS used_cancel
FROM ds_ecom.orders AS o
JOIN ds_ecom.users AS u USING(buyer_id)
LEFT JOIN review_fixed AS r ON o.order_id = r.order_id
LEFT JOIN sum_cost AS s ON o.order_id = s.order_id
LEFT JOIN infocheck AS i ON o.order_id = i.order_id
WHERE o.order_status IN ('Доставлено', 'Отменено') AND u.region IN (SELECT region FROM regions_top)
GROUP BY u.user_id, u.region;


/* Часть 2. Решение ad hoc задач */

/* Задача 1. Сегментация пользователей */

-- Разделение пользователей на сегменты по количеству заказов
SELECT 
    CASE WHEN total_orders = 1 THEN 'сегмент 1 заказ'
         WHEN total_orders BETWEEN 2 AND 5 THEN 'сегмент 2-5 заказов'
         WHEN total_orders BETWEEN 6 AND 10 THEN 'сегмент 6-10 заказов'
         WHEN total_orders >= 11 THEN 'сегмент 11 и более заказов'
    END AS segment,
    COUNT(DISTINCT user_id) AS user_count,
    ROUND(AVG(total_orders), 2) AS avg_to,
    ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_price
FROM ds_ecom.product_user_features
GROUP BY segment
ORDER BY
    CASE segment
        WHEN 'сегмент 1 заказ' THEN 1
        WHEN 'сегмент 2-5 заказов' THEN 2
        WHEN 'сегмент 6-10 заказов' THEN 3
        WHEN 'сегмент 11 и более заказов' THEN 4
    END;

/* Большинство клиентов совершили лишь 1 заказ - таких пользователей 60.468,
 * что составляет подавляющее большинство. Сегмент с 2-5 заказами насчитывает 1.934 человека,
 * с 6-10 заказами всего 5, а постоянных клиентов с 11 и более заказами лишь 1.
 * Прослеживается обратная зависимость: чем больше заказов совершает клиент,
 * тем ниже его средний чек (от 3.324 рублей у разовых покупателей до 1.244 рублей у самых активных).
 * Это может говорить о том, что постоянные клиенты делают небольшие повторные покупки,
 * тогда как разовые покупатели чаще приобретают дорогостоящие товары.
*/


/* Задача 2. Ранжирование пользователей */

-- Топ-15 пользователей с 3+ заказами по убыванию среднего чека
SELECT user_id, region, total_orders, avg_order_cost,
       DENSE_RANK() OVER (ORDER BY avg_order_cost DESC) AS rank
FROM ds_ecom.product_user_features
WHERE total_orders >= 3
ORDER BY avg_order_cost DESC
LIMIT 15;

/* Среди пользователей с 3 и более заказами топ 15 по среднему чеку
 * показывает значения от 6.040 до 14.716 рублей - разница примерно в 2,5 раза.
 * Резкого обрыва нет, значения снижаются плавно.
 * В топе представлены все три региона, лидирует пользователь из Санкт-Петербурга
 * с чеком почти 15.000 рублей.
*/


/* Задача 3. Статистика по регионам */

-- Агрегированная статистика по каждому из трёх регионов
SELECT region,
       COUNT(user_id) AS user_count,
       SUM(total_orders) AS total_ord,
       ROUND(AVG(avg_order_cost), 2) AS avg_price,
       ROUND(SUM(num_installment_orders) * 1.0 / SUM(total_orders), 4) AS dolya_credit,
       ROUND(SUM(num_orders_with_promo) * 1.0 / SUM(total_orders), 4) AS dolya_promo,
       ROUND(AVG(used_cancel), 4) AS dolya_canceled
FROM ds_ecom.product_user_features
GROUP BY region;

/* По всем 3 регионам средняя стоимость заказа примерно одинакова (около 3.200-3.600 рублей),
 * лидирует Санкт-Петербург. Москва является самым крупным регионом
 * по числу клиентов (39.386) и заказов (40.747). Доля заказов в рассрочку высокая
 * во всех регионах (около 47-55%), причём Новосибирская область лидирует по этому показателю.
 * Доля промокодов невысокая (около 3-4%). Доля пользователей с хотя бы 1 отменой
 * очень мала - менее 1% в каждом регионе.
*/


/* Задача 4. Активность пользователей по первому месяцу заказа в 2023 году */

-- Помесячная статистика по пользователям, чей первый заказ был в 2023 году
SET lc_time = 'ru_RU';

SELECT TO_CHAR(first_order_ts, 'TMMonth') AS month_name,
       COUNT(DISTINCT user_id) AS user_count,
       SUM(total_orders) AS total_ord,
       ROUND(AVG(avg_order_cost), 2) AS avg_cost,
       ROUND(AVG(avg_order_rating), 2) AS avg_rating,
       ROUND(AVG(used_money_transfer), 4) AS dolya_money_tr,
       AVG(last_order_ts - first_order_ts)::interval(0) AS avg_activity
FROM ds_ecom.product_user_features
WHERE EXTRACT(YEAR FROM first_order_ts) = 2023
GROUP BY month_name
ORDER BY EXTRACT(MONTH FROM MIN(first_order_ts));

/* Пользователи, совершившие первый заказ в начале 2023 года, демонстрируют
 * более высокую среднюю продолжительность активности (до 12 дней для январских пользователей).
 * Это объясняется тем, что у них было больше времени для повторных заказов.
 * К концу года показатель падает до 2 дней у ноябрьских и декабрьских пользователей.
 * Средний рейтинг стабилен по всем месяцам (около 4.1-4.3).
 * Доля пользователей использующих денежные переводы примерно одинакова (около 20%).
 * Количество клиентов растёт к середине года, пик в ноябре - 4.703 пользователя,
 * что может говорить о сезонном росте активности перед новогодними праздниками.
*/