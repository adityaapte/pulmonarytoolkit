function both_lungs = PTKSeparateAndLabelLungs(unclosed_lungs, filtered_threshold_lung, lung_roi, trachea_top_local, reporting)
    % PTKSeparateAndLabelLungs. Separates left and right lungs from a lung
    %     segmentation.
    %
    %     The left and right lungs are separated using morphological opening
    %     with spherical structural element of increasing size until the left
    %     and right components are separated. Then any voxels removed by the
    %     opening are added to the left and right segmentations using a
    %     watershed algorithm based on the supplied (filtered) image data.
    %
    %     Licence
    %     -------
    %     Part of the TD Pulmonary Toolkit. https://github.com/tomdoel/pulmonarytoolkit
    %     Author: Tom Doel, 2012.  www.tomdoel.com
    %     Distributed under the GNU GPL v3 licence. Please see website for details.
    
    both_lungs = unclosed_lungs.Copy;
    
    % We first use a wide threshold for the lung values and attempt to
    % separate. If not readily separable, then we will try a narrower
    % threshold
    both_lungs.ChangeRawImage(uint8(unclosed_lungs.RawImage & (filtered_threshold_lung.RawImage > 0)));
    [success, max_iter] = SeparateLungs(both_lungs, lung_roi, unclosed_lungs, false, 2, trachea_top_local, reporting);
    
    if ~success
        % For the narrow threshold we allow the full range of separation
        % values
        reporting.ShowMessage('PTKSeparateAndLabelLungs:OpeningLungs', ['Failed to separate left and right lungs after ' int2str(max_iter) ' opening attempts. Trying narrower threshold.']);
        both_lungs.ChangeRawImage(uint8(unclosed_lungs.RawImage & (filtered_threshold_lung.RawImage == 1)));
        [success, max_iter] = SeparateLungs(both_lungs, lung_roi, unclosed_lungs, false, [], trachea_top_local, reporting);
    end

    if ~success
        reporting.ShowMessage('PTKSeparateAndLabelLungs:OpeningLungs', ['Failed to separate left and right lungs after ' int2str(max_iter) ' opening attempts. Trying 2D approach.']);
        both_lungs.ChangeRawImage(uint8(unclosed_lungs.RawImage & (filtered_threshold_lung.RawImage > 0)));

        % 3D approach failed. Try slice-by-slice coronal approach
        results = both_lungs.Copy;
        results.ImageType = PTKImageType.Colormap;
        
        % Create a mask of voxels which could not be allocated to left or right lungs
        voxels_to_remap = both_lungs.Copy;
        voxels_to_remap.Clear;
        
        any_slice_failure = false;
        for coronal_index = 1 : lung_roi.ImageSize(1)
            lung_roi_slice = PTKImage(lung_roi.GetSlice(coronal_index, PTKImageOrientation.Coronal));
            slice_raw = both_lungs.GetSlice(coronal_index, PTKImageOrientation.Coronal);
            slice_raw = imfill(slice_raw, 'holes');
            both_lungs_slice = PTKImage(slice_raw);
            unclosed_lungs_slice = PTKImage(unclosed_lungs.GetSlice(coronal_index, PTKImageOrientation.Coronal));
            if any(both_lungs_slice.RawImage(:))
                [success, max_iter] = SeparateLungs(both_lungs_slice, lung_roi_slice, unclosed_lungs_slice, true, [], trachea_top_local, reporting);
                if ~success
                    any_slice_failure = true;
                    reporting.LogVerbose(['Failed to separate left and right lungs in a coronal slice after ' int2str(max_iter) ' opening attempts. Using nearest neighbour interpolation.']);
                    voxels_to_remap.ReplaceImageSlice(both_lungs_slice.RawImage, coronal_index, PTKImageOrientation.Coronal);
                    both_lungs_slice.Clear;
                end
                
            end
            results_slice = both_lungs_slice;
            results.ReplaceImageSlice(results_slice.RawImage, coronal_index, PTKImageOrientation.Coronal);
        end
        
        if any_slice_failure
            
            % Watershed to fill remaining voxels
            lung_exterior = unclosed_lungs.RawImage == 0;
            starting_voxels = int8(results.RawImage);
            starting_voxels(lung_exterior) = -1;

            labeled_output = PTKWatershedFromStartingPoints(int16(lung_roi.RawImage), starting_voxels);
            labeled_output(labeled_output == -1) = 0;

            results.ChangeRawImage(uint8(labeled_output));
        end
        
        both_lungs = results;
    end
end
    
function [success, max_iter] = SeparateLungs(both_lungs, lung_roi, unclosed_lungs, is_coronal, max_iter, trachea_top_local, reporting)
    
    % Find the connected components in this mask
    CC = bwconncomp(both_lungs.RawImage > 0, 26);
    
    % Find largest regions
    num_pixels = cellfun(@numel, CC.PixelIdxList);
    total_num_pixels = sum(num_pixels);
    [largest_area_numpixels, largest_areas_indices] = sort(num_pixels, 'descend');
        
    if ~isempty(trachea_top_local) && ...
            length(trachea_top_local) > 1 && ...
            length(size(both_lungs.RawImage)) > 2
        left_region = both_lungs.RawImage(:, 1:trachea_top_local(2), :);
        right_region = both_lungs.RawImage(:, trachea_top_local(2) + 1:end, :);
        left_sum = sum(left_region(:));
        right_sum = sum(right_region(:));
        minimum_required_voxels_per_lung = min(left_sum, right_sum)/5;
    else
        minimum_required_voxels_per_lung = total_num_pixels/10;
    end
    
    iter_number = 0;
    opening_sizes = [1, 2, 4, 7, 10, 14];
    if isempty(max_iter)
        max_iter = numel(opening_sizes);
    end
    
    % If there is only one large connected component, the lungs are connected,
    % so we attempt to disconnect them using morphological operations
    while (length(largest_areas_indices) < 2) || (largest_area_numpixels(2) < minimum_required_voxels_per_lung)
        if (iter_number >= max_iter)
            success = false;
            return;
        end
        iter_number = iter_number + 1;
        reporting.LogVerbose(['Failed to separate left and right lungs. Retrying after morphological opening attempt ' num2str(iter_number) '.']);
        opening_size = opening_sizes(iter_number);
        image_to_close = both_lungs.Copy;
        image_to_close.BinaryMorph(@imopen, opening_size);
        
        CC = bwconncomp(image_to_close.RawImage > 0, 26);
        
        % Find largest region
        num_pixels = cellfun(@numel, CC.PixelIdxList);
        total_num_pixels = sum(num_pixels);
        minimum_required_voxels_per_lung = total_num_pixels/10;
        
        [largest_area_numpixels, largest_areas_indices] = sort(num_pixels, 'descend');
        
    end
    
    reporting.LogVerbose('Lung regions found.');
    
    largest_area_index = largest_areas_indices(1);
    second_largest_area_index = largest_areas_indices(2);
    
    region_1_voxels = CC.PixelIdxList{largest_area_index};
    region_1_centroid = GetCentroid(both_lungs.ImageSize, region_1_voxels);
    
    region_2_voxels = CC.PixelIdxList{second_largest_area_index};
    region_2_centroid = GetCentroid(both_lungs.ImageSize, region_2_voxels);
    
    both_lungs.Clear;
    both_lungs.ImageType = PTKImageType.Colormap;
    
    if is_coronal
        dimension_index = 1;
    else
        dimension_index = 2;
    end
    
    if region_1_centroid(dimension_index) < region_2_centroid(dimension_index)
        region_1_colour = 1;
        region_2_colour = 2;
    else
        region_1_colour = 2;
        region_2_colour = 1;
    end
    
    % If both centroids are in the left lung region we assume they both belong
    % to that lung
    if (region_1_centroid(dimension_index) > (both_lungs.ImageSize(dimension_index) / 2)) && ...
       (region_2_centroid(dimension_index) > (both_lungs.ImageSize(dimension_index) / 2))
        region_1_colour = 2;
        region_2_colour = 2;
    end
    
    % If both centroids are in the right lung region we assume they both belong
    % to that lung
    if (region_1_centroid(dimension_index) < (both_lungs.ImageSize(dimension_index) / 2)) && ...
       (region_2_centroid(dimension_index) < (both_lungs.ImageSize(dimension_index) / 2))
        region_1_colour = 1;
        region_2_colour = 1;
    end
    

    
    % Watershed to fill remaining voxels
    lung_exterior = unclosed_lungs.RawImage == 0;
    starting_voxels = zeros(both_lungs.ImageSize, 'int8');
    starting_voxels(region_1_voxels) = region_1_colour;
    starting_voxels(region_2_voxels) = region_2_colour;
    starting_voxels(lung_exterior) = -1;
    
    labeled_output = PTKWatershedFromStartingPoints(int16(lung_roi.RawImage), starting_voxels);
    labeled_output(labeled_output == -1) = 0;
    
    both_lungs.ChangeRawImage(uint8(labeled_output));
    both_lungs.ImageType = PTKImageType.Colormap;
    success = true;
end

function centroid = GetCentroid(image_size, new_coords_indices)
    [p_x, p_y, p_z] = MimImageCoordinateUtilities.FastInd2sub(image_size, new_coords_indices);
    centroid = [mean(p_x), mean(p_y), mean(p_z)];
end