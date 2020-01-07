package com.bitpay.cordova.qrscanner;

import android.content.Context;
import android.graphics.Rect;

import com.journeyapps.barcodescanner.BarcodeView;

public class BarcodePreview extends BarcodeView {
    // Web app measures in browser pixels
    private final int headerHeightLargeWeb = 60; // large header of the web app in browser px
    private final int headerHeightSmallWeb = 48; // small header of the web app in browser px
    private final int sideMarginsWeb = 16; // side margins of the web app in browser px
    private final int widthBreakpointWeb = 600; // above this breakpoint in browser px the width is fixed

    private Context context;

    public BarcodePreview(Context context) {
        super(context);
        this.context = context;
    }

    /**
     * Calculates the framing rectangle of the camera view in which the barcode is captured.
     *
     * 1. If app screen width > (600 browser pixels * display density)
     * scanning window width = (568 browser pixels * display density)
     * scanning window height = 1/2 scanning window width
     * scanning window top = (60 browser pixels * display density)
     * scanning window left = (app screen width - scanning window width) / 2
     * 
     * 2. If app screen width <= (600 browser pixels * display density)
     * scanning window width = app screen width - (2 * 16 browser pixels * display density)
     * scanning window height = 1/2 scanning window width
     * scanning window top = (48 browser pixels * display density)
     * scanning window left = (16 browser pixels * display density)
     *
     * @param container
     * @param surface
     * @return the framing rectangle for the camera
     */
    @Override
    protected Rect calculateFramingRect(Rect container, Rect surface) {
        float displayDensity = context.getResources().getDisplayMetrics().density;
        int containerWidth = context.getResources().getDisplayMetrics().widthPixels; // app screen width
        int widthBreakpoint = Math.round(widthBreakpointWeb * displayDensity); // width breakpoint in display px
        int minWidth = Math.min(widthBreakpoint, containerWidth); // smallest between width breakpoint and container width
        int rectWidth = minWidth - Math.round(sideMarginsWeb * displayDensity * 2);
        int rectHeight = rectWidth / 2;
        int left = (containerWidth - rectWidth) / 2;
        int right = left + rectWidth;
        int headerHeightWeb = containerWidth <= widthBreakpoint ? headerHeightSmallWeb : headerHeightLargeWeb; // header height in browser px
        int top = Math.round(headerHeightWeb * displayDensity);
        int bottom = top + rectHeight;

        Rect framingRect = new Rect(left, top, right, bottom);

        return framingRect;
    }
}
