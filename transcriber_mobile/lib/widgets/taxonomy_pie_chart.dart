import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/analytics.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class TaxonomyPieChart extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String tag;
  final List<TaxonomyItem> items;
  final bool isDark;

  const TaxonomyPieChart({
    super.key,
    required this.title,
    this.subtitle,
    required this.tag,
    required this.items,
    required this.isDark,
  });

  @override
  State<TaxonomyPieChart> createState() => _TaxonomyPieChartState();
}

class _TaxonomyPieChartState extends State<TaxonomyPieChart> {
  int _touchedIndex = -1;

  static const List<Color> _palette = [
    Color(0xFF10B981), // Emerald
    Color(0xFF06B6D4), // Cyan
    Color(0xFFA855F7), // Purple
    Color(0xFFF59E0B), // Amber
    Color(0xFFF43F5E), // Rose
    Color(0xFF3B82F6), // Blue
    Color(0xFF14B8A6), // Teal
    Color(0xFF8B5CF6), // Indigo
  ];

  @override
  Widget build(BuildContext context) {
    final validItems = widget.items.where((it) => it.count > 0).toList();
    final totalCount = validItems.fold<int>(0, (sum, it) => sum + it.count);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: widget.isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          color: widget.isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.emeraldPrimary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.35)),
                ),
                child: Text(
                  widget.tag,
                  style: AppTheme.mono(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.emeraldLight,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (validItems.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No telemetry recorded yet',
                  style: AppTheme.mono(
                    fontSize: 11.5,
                    color: widget.isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                  ),
                ),
              ),
            )
          else ...[
            // Donut PieChart
            SizedBox(
              height: 170,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      pieTouchData: PieTouchData(
                        touchCallback: (FlTouchEvent event, pieTouchResponse) {
                          setState(() {
                            if (!event.isInterestedForInteractions ||
                                pieTouchResponse == null ||
                                pieTouchResponse.touchedSection == null) {
                              _touchedIndex = -1;
                              return;
                            }
                            _touchedIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
                          });
                        },
                      ),
                      borderData: FlBorderData(show: false),
                      sectionsSpace: 2.5,
                      centerSpaceRadius: 42,
                      sections: List.generate(validItems.length, (i) {
                        final item = validItems[i];
                        final isTouched = i == _touchedIndex;
                        final radius = isTouched ? 36.0 : 30.0;
                        final color = _palette[i % _palette.length];

                        return PieChartSectionData(
                          color: color,
                          value: item.count.toDouble(),
                          title: '${item.percentage.toStringAsFixed(0)}%',
                          radius: radius,
                          titleStyle: AppTheme.mono(
                            fontSize: isTouched ? 11.5 : 10.0,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        );
                      }),
                    ),
                  ),

                  // Center Badge
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$totalCount',
                        style: AppTheme.mono(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: widget.isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      Text(
                        'TOTAL',
                        style: AppTheme.mono(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: widget.isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Legend Rows
            Column(
              children: List.generate(validItems.length, (idx) {
                final item = validItems[idx];
                final color = _palette[idx % _palette.length];
                final isSelected = idx == _touchedIndex;

                return InkWell(
                  onTap: () {
                    setState(() {
                      _touchedIndex = _touchedIndex == idx ? -1 : idx;
                    });
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSelected ? color.withOpacity(0.12) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.name,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                              color: widget.isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${item.percentage.toStringAsFixed(1)}%',
                            style: AppTheme.mono(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${item.count}',
                          style: AppTheme.mono(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: widget.isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }
}
